library hexastar;

{$define fpc}
{$IFDEF fpc}
{$MODE objfpc}
{$ENDIF}

{$ifdef q}
        {$define odd-q}
{$endif}
{$H+}

uses
  SysUtils,{$IFNDEF fpc}
  Math,{$ENDIF}
  //  Classes,
  Windows;

  //------------------------------------------------------------------------------
  // ТИПЫ ДАННЫХ
  //------------------------------------------------------------------------------
type
  // Тип для стоимости ячейки
  TCellCost = double;

  // Карта
  PMap = ^TMap;

  TMap = record
    ID: integer;
    Width: integer;
    Height: integer;
    Cells: array of TCellCost;
    // Динамический массив стоимостей
    IsValid: boolean;
  end;

  // Точка пути
  TPathPoint = record
    q, r: integer;
  end;

  // Объект пути
  PPath = ^TPath;

  TPath = record
    ID: integer;
    Points: array of TPathPoint; // Массив точек пути
    Length: integer; // Количество точек (0..Length-1)
    IsValid: boolean;
  end;

  // Узел для бинарной кучи A*
  // TAStarNode = record
  //  q, r: Integer;
  //  g, f: Double;
  //  cellIndex: Integer; // ДОБАВИЛИ - индекс ячейки для быстрого сравнения
  // end;
  TAStarNode = record
    q, r: integer;
    g, f: double;
    cellIndex: integer;
    // индекс ячейки для быстрого сравнения
    cameFromDir: integer;
    // направление, откуда пришли (0..5 или -1 для старта)
  end;
  // Бинарная куча (min-heap) для A*
  TAStarHeap = record
    items: array of TAStarNode;
    Count: integer;
  end;
  //------------------------------------------------------------------------------
  // КОНСТАНТЫ
  //------------------------------------------------------------------------------
  // Направления для гексагональной сетки (axial coordinates, pointy-top)
const
  HEX_DIR_COUNT = 6;

  HexDirections: array[0..5] of record
      dq, dr: integer;
      end
  = ((dq: 1; dr: 0), // Восток
    (dq: 1; dr: -1), // Северо-восток
    (dq: 0; dr: -1), // Северо-запад
    (dq: -1; dr: 0), // Запад
    (dq: -1; dr: 1), // Юго-запад
    (dq: 0; dr: 1)); // Юго-восток

  //------------------------------------------------------------------------------
  // ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ DLL
  //------------------------------------------------------------------------------
var
  // Хранение карт
  Maps: array of PMap;
  MapCount: integer = 0;
  NextMapID: integer = 1;

  // Хранение путей
  Paths: array of PPath;
  PathCount: integer = 0;
  NextPathID: integer = 1;
  {$IFDEF DEBUG}
  InfoBuffer: array[0..511] of AnsiChar;
  {$ENDIF}
  MapInfoBuffer: array[0..511] of ansichar;

  // Хэш-таблицы для быстрого поиска
  MapHash: array[0..1023] of PMap; // 1024 слота для карт
  PathHash: array[0..1023] of PPath; // 1024 слота для путей

  // Критическая секция для потокобезопасности
  CS: TRTLCriticalSection;
  //------------------------------------------------------------------------------
  // ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
  //------------------------------------------------------------------------------
  // Отладочный вывод в OutputDebugString

  {$IFDEF DEBUG}

  procedure DebugLog(const Msg: string);
  begin
    OutputDebugString(PChar('HexAStar: ' + Msg));
  end;
  {$ENDIF}
  // Блокировка для потокобезопасности
  procedure LockDLL;
  begin
    EnterCriticalSection(CS);
  end;
  // Разблокировка для потокобезопасности
  procedure UnlockDLL;
  begin
    LeaveCriticalSection(CS);
  end;

  function GetMapHash(ID: integer): integer;
  begin
    // Быстрая битовая операция: ID mod 1024
    Result := ID and 1023;
  end;

  function GetPathHash(ID: integer): integer;
  begin
    Result := ID and 1023;
  end;

  // Поиск карты по ID
  function FindMapByID(ID: integer): PMap;
  var
    HashIdx: integer;
    i: integer;
  begin
    Result := nil;
    if ID <= 0 then
    begin
      Exit;
    end;
    if ID > 10000000 then
    begin
      Exit;
    end;
    // 1. Быстрый поиск через хэш-таблицу (O(1))
    HashIdx := GetMapHash(ID);
    if HashIdx < 0 then
    begin
      Exit;
    end;
    if (MapHash[HashIdx] <> nil) and (MapHash[HashIdx]^.ID = ID) and MapHash[HashIdx]^.IsValid then
    begin
      Result := MapHash[HashIdx];
      Exit;
    end;

    // 2. Если в хэше не нашли (коллизия или устаревшие данные) - линейный поиск
    for i := 0 to MapCount - 1 do
    begin
      if (Maps[i] <> nil) and (Maps[i]^.ID = ID) and Maps[i]^.IsValid then
      begin
        Result := Maps[i];
        // Обновляем хэш-таблицу для будущих быстрых поисков
        MapHash[HashIdx] := Maps[i];
        Exit;
      end;
    end;
  end;

  // Поиск пути по ID
  function FindPathByID(ID: integer): PPath;
  var
    HashIdx: integer;
    i: integer;
  begin
    Result := nil;
    if ID <= 0 then
    begin
      Exit;
    end;

    // 1. Быстрый поиск через хэш-таблицу
    HashIdx := GetPathHash(ID);
    if (PathHash[HashIdx] <> nil) and (PathHash[HashIdx]^.ID = ID) and PathHash[HashIdx]^.IsValid then
    begin
      Result := PathHash[HashIdx];
      Exit;
    end;

    // 2. Линейный поиск при коллизии
    for i := 0 to PathCount - 1 do
    begin
      if (Paths[i] <> nil) and (Paths[i]^.ID = ID) and Paths[i]^.IsValid then
      begin
        Result := Paths[i];
        // Обновляем хэш-таблицу
        PathHash[HashIdx] := Paths[i];
        Exit;
      end;
    end;
  end;

  // Проверка валидности координат
  function IsValidCoord(Map: PMap; q, r: integer): boolean;
  var
    ox, oy: integer;
  begin
    Result := (Map <> nil);
    if not Result then
    begin
      Exit;
    end;

    {$IFDEF odd-q}
    ox := q;
    oy := r + (q - (q mod 2)) div 2;
    {$ELSE}
    ox := q + (r - (r mod 2)) div 2;
    oy := r;
    {$ENDIF}
    Result := (ox >= 0) and (ox < Map^.Width) and (oy >= 0) and (oy < Map^.Height);
  end;

  // Получение индекса ячейки в массиве (row-major: r * Width + q)
  function GetCellIndex(Map: PMap; q, r: integer): integer;
  var
    ox, oy: integer;
  begin
    {$IFDEF odd-q}
    // axial ’ offset (odd-q, flat-top)
    ox := q;
    oy := r + (q - (q mod 2)) div 2;
    Result := oy * Map^.Width + ox;
    {$ELSE}
    ox := q + (r - (r mod 2)) div 2;
    oy := r;
    Result := oy * Map^.Width + ox;
    {$ENDIF}
  end;

  function GenerateMapID: integer;
  begin
    // Ищем свободный ID
    repeat
      Inc(NextMapID);
      if NextMapID > 1000000 then
      begin
        NextMapID := 1;
      end;

      // Проверяем, не занят ли этот ID
      if FindMapByID(NextMapID) = nil then
      begin
        Break;
      end;

      // Если занят, пробуем следующий (максимум 100 попыток)
      if NextMapID >= 1000100 then
      begin
        NextMapID := 1;
        Break;
      end;
    until False;

    Result := NextMapID;
  end;

  function GeneratePathID: integer;
  begin
    // Ищем свободный ID
    repeat
      Inc(NextPathID);
      if NextPathID > 1000000 then
      begin
        NextPathID := 1;
      end;

      // Проверяем, не занят ли этот ID
      if FindPathByID(NextPathID) = nil then
      begin
        Break;
      end;

      // Если занят, пробуем следующий
      if NextPathID >= 1000100 then
      begin
        NextPathID := 1;
        Break;
      end;
    until False;

    Result := NextPathID;
  end;

  function HexHeuristic(q1, r1, q2, r2: integer): double;
  var
    dq, dr, ds: integer;
  begin
    dq := q2 - q1;
    dr := r2 - r1;
    ds := -dq - dr; // Кубическая координата s
    // Максимальная абсолютная разность по трем осям
    Result := Max(Abs(dq), Max(Abs(dr), Abs(ds)));
  end;

  //------------------------------------------------------------------------------
  // ФУНКЦИИ КОНВЕРТАЦИИ COORDINATES (odd-q offset)
  //------------------------------------------------------------------------------

  // Конвертация offset (odd-q) ’ axial координат
  procedure OffsetToAxial(offsetX, offsetY: integer; var axialQ, axialR: integer);
  begin
    // В odd-q offset:
    // axial.q = offset.col
    // axial.r = offset.row - (offset.col - (offset.col mod 2)) div 2
    try
      // Проверка на возможное переполнение
      if (offsetX < -32768) or (offsetX > 32767) then
      begin
        axialQ := 0;
        axialR := 0;
        Exit;
      end;
      {$IFDEF odd-q}
      axialQ := offsetX;
      axialR := offsetY - (offsetX - (offsetX mod 2)) div 2;
      {$ELSE}// odd-r
      axialQ := offsetX - (offsetY - (offsetY mod 2)) div 2;
      axialR := offsetY;
      {$ENDIF}
    except
      on E: Exception do
      begin
        axialQ := 0;
        axialR := 0;
        {$IFDEF DEBUG}
        DebugLog('OffsetToAxial exception: ' + E.Message);
        {$ENDIF}
      end;
    end;
  end;

  // Конвертация axial ’ offset (odd-q) координат
  procedure AxialToOffset(axialQ, axialR: integer; var offsetX, offsetY: integer);
  begin
    {$IFDEF odd-q}
    offsetX := axialQ;
    offsetY := axialR + (axialQ - (axialQ mod 2)) div 2;
    {$ELSE}// odd-r
    offsetX := axialQ + (axialR - (axialR mod 2)) div 2;
    offsetY := axialR;
    {$ENDIF}
  end;

  // Проверка валидности offset координат (быстрая, без конвертации)
  function IsValidOffsetCoord(Map: PMap; offsetX, offsetY: integer): boolean;
  begin
    Result := (Map <> nil) and (offsetX >= 0) and (offsetX < Map^.Width) and (offsetY >= 0) and (offsetY < Map^.Height);
  end;

  // Получение индекса ячейки напрямую из offset координат
  // function GetCellIndexFromOffset(Map: PMap; offsetX, offsetY: Integer): Integer;
  // begin
  //  Result := offsetY * Map^.Width + offsetX;
  // end;

  // Вспомогательная: конвертация offset ’ axial и получение индекса
  // function GetCellIndexFromOffsetViaAxial(Map: PMap; offsetX, offsetY: Integer): Integer;
  // var
  //  axialQ, axialR: Integer;
  // begin
  //  OffsetToAxial(offsetX, offsetY, axialQ, axialR);
  //  Result := GetCellIndex(Map, axialQ, axialR);
  // end;

  //------------------------------------------------------------------------------
  // БИНАРНАЯ КУЧА (MIN-HEAP) ДЛЯ A*
  //------------------------------------------------------------------------------

  procedure HeapInit(var Heap: TAStarHeap);
  begin
    Heap.Count := 0;
    SetLength(Heap.items, 8192); // Начальный размер
  end;

  procedure HeapGrow(var Heap: TAStarHeap);
  begin
    if Heap.Count >= Length(Heap.items) then
    begin
      SetLength(Heap.items, Length(Heap.items) * 2);
    end;
  end;

  procedure HeapSwap(var Heap: TAStarHeap; a, b: integer);
  var
    temp: TAStarNode;
  begin
    temp := Heap.items[a];
    Heap.items[a] := Heap.items[b];
    Heap.items[b] := temp;
  end;

  // Всплытие элемента вверх
  procedure HeapBubbleUp(var Heap: TAStarHeap; idx: integer);
  var
    parent: integer;
  begin
    while idx > 0 do
    begin
      parent := (idx - 1) div 2;

      // Если текущий элемент больше или равен родителю - останавливаемся
      if Heap.items[idx].f >= Heap.items[parent].f then
      begin
        Break;
      end;

      HeapSwap(Heap, idx, parent);
      idx := parent;
    end;
  end;

  // Просеивание элемента вниз
  procedure HeapBubbleDown(var Heap: TAStarHeap; idx: integer);
  var
    left, right, smallest: integer;
  begin
    while True do
    begin
      left := idx * 2 + 1;
      right := left + 1;
      smallest := idx;

      // Ищем наименьший среди текущего, левого и правого детей
      if (left < Heap.Count) and (Heap.items[left].f < Heap.items[smallest].f) then
      begin
        smallest := left;
      end;

      if (right < Heap.Count) and (Heap.items[right].f < Heap.items[smallest].f) then
      begin
        smallest := right;
      end;

      // Если текущий элемент уже наименьший - выходим
      if smallest = idx then
      begin
        Break;
      end;

      HeapSwap(Heap, idx, smallest);
      idx := smallest;
    end;
  end;
  // Добавление элемента в кучу

  procedure HeapPush(var Heap: TAStarHeap; const Node: TAStarNode);
  begin
    try
      HeapGrow(Heap);
      // Проверка на валидность индекса
      if Heap.Count >= Length(Heap.items) then
      begin
        Exit;
      end; // На случай, если HeapGrow не сработал
      Heap.items[Heap.Count] := Node;
      Inc(Heap.Count);
      HeapBubbleUp(Heap, Heap.Count - 1);
    except
      on E: Exception do
      begin
        {$IFDEF DEBUG}
        DebugLog('HeapPush exception: ' + E.Message);
        {$ENDIF}
      end;
    end;
  end;

  // Извлечение минимального элемента
  function HeapPop(var Heap: TAStarHeap): TAStarNode;
  begin
    if Heap.Count = 0 then
    begin
      // Возвращаем пустой узел в случае ошибки
      Result.q := -1;
      Result.r := -1;
      Result.g := 1E100;
      Result.f := 1E100;
      Result.cellIndex := -1;
      Result.cameFromDir := -1; // Добавляем
      Exit;
    end;

    Result := Heap.items[0];
    Dec(Heap.Count);

    if Heap.Count > 0 then
    begin
      // Перемещаем последний элемент в корень
      Heap.items[0] := Heap.items[Heap.Count];
      HeapBubbleDown(Heap, 0);
    end;
  end;

  function HeapIsEmpty(const Heap: TAStarHeap): boolean;
  begin
    Result := Heap.Count = 0;
  end;
  //------------------------------------------------------------------------------
  // A* АЛГОРИТМ ДЛЯ ГЕКСАГОНАЛЬНОЙ СЕТКИ С БИНАРНОЙ КУЧЕЙ
  //------------------------------------------------------------------------------

  function Internal_FindPath(Map: PMap; Path: PPath; StartQ, StartR, GoalQ, GoalR: integer; AllowSolid, IgnoreCost: boolean): boolean;
  const
    DIR_PENALTY_FACTOR = 0.15; // 15% от стоимости
    DIR_PENALTY_MAX = 0.5;  // максимум
  var
    Heap: TAStarHeap;
    cameFrom: array of integer;
    cameFromDir: array of integer; // Добавили: массив направлений
    gScore: array of double;
    closed: array of boolean;
    bestG: array of double;
    mapSize, startIdx, goalIdx, pathLen, cur: integer;
    i, nq, nr, currIdx, neighborIdx: integer;
    cellCost, moveCost, tentativeG: double;
    Current, Neighbor: TAStarNode;
    ox, oy: integer; // для конвертации offset -> axial
  begin
    Result := False;
    // Дополнительные проверки
    if (Map = nil) or (Path = nil) then
    begin
      Exit;
    end;
    if not Map^.IsValid then
    begin
      Exit;
    end;
    if not IsValidCoord(Map, StartQ, StartR) or not IsValidCoord(Map, GoalQ, GoalR) then
    begin
      Exit;
    end;
    // Проверка размеров карты
    if (Map^.Width <= 0) or (Map^.Height <= 0) then
    begin
      Exit;
    end;
    if (Length(Map^.Cells) <> Map^.Width * Map^.Height) then
    begin
      Exit;
    end;

    // индексы старта и цели
    startIdx := GetCellIndex(Map, StartQ, StartR);
    goalIdx := GetCellIndex(Map, GoalQ, GoalR);
    if (startIdx < 0) or (goalIdx < 0) then
    begin
      Exit;
    end;

    // старт = цель
    if startIdx = goalIdx then
    begin
      Path^.Length := 1;
      if Length(Path^.Points) < 1 then
      begin
        SetLength(Path^.Points, 1);
      end;
      Path^.Points[0].q := StartQ;
      Path^.Points[0].r := StartR;
      Exit;
    end;

    mapSize := Map^.Width * Map^.Height;
    SetLength(cameFrom, mapSize);
    SetLength(cameFromDir, mapSize);
    // Инициализируем массив направлений
    SetLength(gScore, mapSize);
    SetLength(closed, mapSize);
    SetLength(bestG, mapSize);

    HeapInit(Heap);
    try
      for i := 0 to mapSize - 1 do
      begin
        cameFrom[i] := -1;
        cameFromDir[i] := -1; // -1 означает "нет направления"
        gScore[i] := 1E100;
        bestG[i] := 1E100;
        closed[i] := False;
      end;

      Current.q := StartQ;
      Current.r := StartR;
      Current.g := 0.0;
      Current.f := HexHeuristic(StartQ, StartR, GoalQ, GoalR);
      Current.cellIndex := startIdx;
      Current.cameFromDir := -1;
      // Стартовая точка - нет предыдущего направления

      HeapPush(Heap, Current);
      gScore[startIdx] := 0.0;
      bestG[startIdx] := 0.0;
      cameFromDir[startIdx] := -1; // Старт

      while not HeapIsEmpty(Heap) do
      begin
        Current := HeapPop(Heap);
        currIdx := Current.cellIndex;

        // фильтрация устаревших записей
        if closed[currIdx] or (Current.g > bestG[currIdx] + 0.0001) then
        begin
          Continue;
        end;

        closed[currIdx] := True;

        if currIdx = goalIdx then
        begin
          // Восстанавливаем путь
          pathLen := 0;
          cur := goalIdx;
          while cur <> -1 do
          begin
            Inc(pathLen);
            cur := cameFrom[cur];
          end;

          Path^.Length := pathLen;
          if Length(Path^.Points) < pathLen then
          begin
            SetLength(Path^.Points, pathLen);
          end;

          cur := goalIdx;
          for i := pathLen - 1 downto 0 do
          begin
            {$IFDEF odd-q}
            // Получаем offset-координаты из индекса
            ox := cur mod Map^.Width;
            oy := cur div Map^.Width;

            // Конвертируем offset ’ axial
            Path^.Points[i].q := ox;
            Path^.Points[i].r := oy - (ox - (ox mod 2)) div 2;
            {$ELSE}
            ox := cur mod Map^.Width;
            oy := cur div Map^.Width;

            Path^.Points[i].q := ox - (oy - (oy mod 2)) div 2;
            Path^.Points[i].r := oy;
            {$ENDIF}
            cur := cameFrom[cur];
          end;

          Result := True;
          Exit;
        end;

        // Обходим соседей
        for i := 0 to HEX_DIR_COUNT - 1 do
        begin
          nq := Current.q + HexDirections[i].dq;
          nr := Current.r + HexDirections[i].dr;

          if not IsValidCoord(Map, nq, nr) then
          begin
            Continue;
          end;

          neighborIdx := GetCellIndex(Map, nq, nr);
          if closed[neighborIdx] then
          begin
            Continue;
          end;

          cellCost := Map^.Cells[neighborIdx];

          // семантика:
          // cellCost < 0  > стена
          // AllowSolid    > разрешить проход со стоимостью 1
          if (cellCost < 0) then
          begin
            if not AllowSolid then
            begin
              Continue;
            end;
            moveCost := 1.0;
          end
          else
          begin
            if IgnoreCost then
            begin
              moveCost := 1.0;
            end
            else
            begin
              moveCost := cellCost;
            end;
          end;

          // ДОБАВЛЯЕМ ПЕНАЛЬТИ ЗА ПОВТОР НАПРАВЛЕНИЯ (0.1)
          if (Current.cameFromDir = i) and (Current.cameFromDir <> -1) then
          begin
            // штраф пропорционален стоимости клетки
            moveCost := moveCost + cellCost * DIR_PENALTY_FACTOR;
            // насыщение
            if moveCost > (cellCost + DIR_PENALTY_MAX) then
            begin
              moveCost := cellCost + DIR_PENALTY_MAX;
            end;
          end;

          tentativeG := Current.g + moveCost;

          if tentativeG < gScore[neighborIdx] then
          begin
            cameFrom[neighborIdx] := currIdx;
            cameFromDir[neighborIdx] :=
              i; // Запоминаем направление
            gScore[neighborIdx] := tentativeG;
            bestG[neighborIdx] := tentativeG;

            Neighbor.q := nq;
            Neighbor.r := nr;
            Neighbor.g := tentativeG;
            Neighbor.f := tentativeG + HexHeuristic(nq, nr, GoalQ, GoalR);
            Neighbor.cellIndex := neighborIdx;
            Neighbor.cameFromDir := i;
            // Передаём направление в узел

            HeapPush(Heap, Neighbor);
          end;
        end;
      end;
    finally
      Heap.Count := 0;
      SetLength(Heap.items, 0);
      SetLength(cameFrom, 0);
      SetLength(cameFromDir, 0);
      SetLength(gScore, 0);
      SetLength(closed, 0);
      SetLength(bestG, 0);
    end;
  end;

  //------------------------------------------------------------------------------
  // ФУНКЦИИ ДЛЯ РАБОТЫ С КАРТАМИ (ЭКСПОРТИРУЕМЫЕ)
  //------------------------------------------------------------------------------

  function map_create(Width, Height: double): double; cdecl;
  var
    Map: PMap;
    w, h, i: integer;
  begin
    Result := 0.0;

    w := Trunc(Width);
    h := Trunc(Height);
    if (w <= 0) or (h <= 0) then
    begin
      {$IFDEF DEBUG}
      DebugLog('map_create: Invalid dimensions');
      {$ENDIF}
      Exit;
    end;

    LockDLL;
    try
      try
        // Выделяем память
        New(Map);

        // Инициализируем поля
        Map^.ID := GenerateMapID;
        // Используем нашу функцию без коллизий
        Map^.Width := w;
        Map^.Height := h;
        Map^.IsValid := True;

        // Выделяем массив ячеек
        SetLength(Map^.Cells, w * h);

        // Инициализируем все ячейки значением 1.0 (проходимые)
        for i := 0 to w * h - 1 do
        begin
          Map^.Cells[i] := 1.0;
        end;

        // Добавляем в глобальный массив
        if MapCount >= Length(Maps) then
        begin
          SetLength(Maps, Length(Maps) + 10);
        end;

        Maps[MapCount] := Map;
        Inc(MapCount);

        // ДОБАВЛЯЕМ В ХЭШ-ТАБЛИЦУ
        MapHash[GetMapHash(Map^.ID)] := Map;

        // Возвращаем handle
        Result := Map^.ID;
        {$IFDEF DEBUG}
        DebugLog(Format('map_create: Map %d created (%dx%d)', [Map^.ID, w, h]));
        {$ENDIF}
      except
        on E: Exception do
        begin
          {$IFDEF DEBUG}
          DebugLog('map_create EXCEPTION: ' + E.Message);
          {$ENDIF}
          if Map <> nil then
          begin
            Dispose(Map);
          end;
          Result := 0.0;
        end;
      end;
    finally
      UnlockDLL;
    end;
  end;

  function map_destroy(mapHandle: double): double; cdecl;
  var
    i, Handle, LastIdx: integer;
    Map, LastMap: PMap;
    hashIdxDel, hashIdxMove: integer;
  begin
    Result := 0.0;

    try
      Handle := Trunc(mapHandle);
    except
      Exit;
    end;

    if Handle <= 0 then
    begin
      {$IFDEF DEBUG}
      DebugLog('map_destroy: Invalid handle');
      {$ENDIF}
      Exit;
    end;

    LockDLL;
    try
      for i := 0 to MapCount - 1 do
      begin
        if (Maps[i] <> nil) and (Maps[i]^.ID = Handle) then
        begin
          Map := Maps[i];
          try
            hashIdxDel := GetMapHash(Map^.ID);
            if MapHash[hashIdxDel] = Map then
            begin
              MapHash[hashIdxDel] := nil;
            end;
            Map^.IsValid := False;
            SetLength(Map^.Cells, 0);
            Dispose(Map);
            LastIdx := MapCount - 1;
            if i < LastIdx then
            begin
              LastMap := Maps[LastIdx];
              Maps[i] := LastMap;
              if LastMap <> nil then
              begin
                hashIdxMove := GetMapHash(LastMap^.ID);
                if MapHash[hashIdxMove] = LastMap then
                begin
                  MapHash[hashIdxMove] := Maps[i];
                end;
              end;
            end;
            Maps[LastIdx] := nil;
            Dec(MapCount);

            Result := 1.0;
            {$IFDEF DEBUG}
            DebugLog(Format('map_destroy: Map %d destroyed', [Handle]));
            {$ENDIF}
          except
            on E: Exception do
            begin
              {$IFDEF DEBUG}
              DebugLog('map_destroy EXCEPTION: ' + E.Message);
              {$ENDIF}
              Result := 0.0;
            end;
          end;

          Exit;
        end;
      end;

      {$IFDEF DEBUG}
      DebugLog(Format('map_destroy: Map %d not found', [Handle]));
      {$ENDIF}
    finally
      UnlockDLL;
    end;
  end;

  function map_destroy_all(): double; cdecl;
  var
    i: integer;
    hashIdx: integer;
  begin
    LockDLL;
    try
      try
        for i := 0 to MapCount - 1 do
        begin
          if Maps[i] <> nil then
          begin
            hashIdx := GetMapHash(Maps[i]^.ID);
            if MapHash[hashIdx] = Maps[i] then
            begin
              MapHash[hashIdx] := nil;
            end;

            Maps[i]^.IsValid := False;
            SetLength(Maps[i]^.Cells, 0);
            Dispose(Maps[i]);
            Maps[i] := nil;
          end;
        end;
        FillChar(MapHash, SizeOf(MapHash), 0);
        MapCount := 0;
        SetLength(Maps, 0);

        Result := 1.0;

        {$IFDEF DEBUG}
        DebugLog('map_destroy_all: All maps destroyed, hash table cleared');
        {$ENDIF}

      except
        on E: Exception do
        begin
          {$IFDEF DEBUG}
          DebugLog('map_destroy_all EXCEPTION: ' + E.Message);
          {$ENDIF}
          Result := 0.0;
        end;
      end;
    finally
      UnlockDLL;
    end;
  end;

  function map_set_cell(mapHandle, offsetX, offsetY, Value: double): double; cdecl;
  var
    Handle, xCoord, yCoord: integer;
    Map: PMap;
    Index: integer;
    axialQ, axialR: integer;
  begin
    Result := 0.0;
    Handle := Trunc(mapHandle);
    xCoord := Trunc(offsetX);
    yCoord := Trunc(offsetY);

    LockDLL;
    try
      try
        Map := FindMapByID(Handle);
        if Map = nil then
        begin
          {$IFDEF DEBUG}
          DebugLog('map_set_cell: Map not found');
          {$ENDIF}
          Exit;
        end;

        // Проверяем offset координаты
        if not IsValidOffsetCoord(Map, xCoord, yCoord) then
        begin
          {$IFDEF DEBUG}
          DebugLog(Format('map_set_cell: Invalid offset coordinates (%d,%d)', [xCoord, yCoord]));
          {$ENDIF}
          Exit;
        end;

        // Конвертируем offset ’ axial
        OffsetToAxial(xCoord, yCoord, axialQ, axialR);

        // Получаем индекс (работает с axial)
        Index := GetCellIndex(Map, axialQ, axialR);
        Map^.Cells[Index] := Value;

        Result := 1.0;

      except
        on E: Exception do
        begin
          {$IFDEF DEBUG}
          DebugLog('map_set_cell EXCEPTION: ' + E.Message);
          {$ENDIF}
          Result := 0.0;
        end;
      end;
    finally
      UnlockDLL;
    end;
  end;

  function map_get_cell(mapHandle, offsetX, offsetY: double): double; cdecl;
  var
    Handle, xCoord, yCoord: integer;
    Map: PMap;
    Index: integer;
    axialQ, axialR: integer;
  begin
    Result := -1.0; // По умолчанию - ошибка

    Handle := Trunc(mapHandle);
    xCoord := Trunc(offsetX);
    yCoord := Trunc(offsetY);

    LockDLL;
    try
      try
        Map := FindMapByID(Handle);
        if Map = nil then
        begin
          {$IFDEF DEBUG}
          DebugLog('map_get_cell: Map not found');
          {$ENDIF}
          Exit;
        end;

        // Проверяем offset координаты
        if not IsValidOffsetCoord(Map, xCoord, yCoord) then
        begin
          {$IFDEF DEBUG}
          DebugLog(Format('map_get_cell: Invalid offset coordinates (%d,%d)', [xCoord, yCoord]));
          {$ENDIF}
          Exit;
        end;

        // Конвертируем offset ’ axial
        OffsetToAxial(xCoord, yCoord, axialQ, axialR);

        Index := GetCellIndex(Map, axialQ, axialR);
        Result := Map^.Cells[Index];

      except
        on E: Exception do
        begin
          {$IFDEF DEBUG}
          DebugLog('map_get_cell EXCEPTION: ' + E.Message);
          {$ENDIF}
          Result := -1.0;
        end;
      end;
    finally
      UnlockDLL;
    end;
  end;

  // Исправляем функции:
  function map_get_info(mapHandle: double): pansichar; cdecl;
  var
    Handle: integer;
    Map: PMap;
    InfoStr: ansistring;
  begin
    // Заполняем буфер ошибкой по умолчанию
    StrPLCopy(MapInfoBuffer, 'Map not found', SizeOf(MapInfoBuffer) - 1);
    Result := @MapInfoBuffer[0];
    Handle := Trunc(mapHandle);
    LockDLL;
    try
      try
        Map := FindMapByID(Handle);
        if Map = nil then
        begin
          Exit;
        end;
        InfoStr :=
          ansistring(Format('ID:%d, Size:%dx%d, Cells:%d', [Map^.ID, Map^.Width, Map^.Height, Length(Map^.Cells)]));
        // Копируем в глобальный буфер
        StrPLCopy(MapInfoBuffer, InfoStr, SizeOf(MapInfoBuffer) - 1);
        Result := @MapInfoBuffer[0];
      except
        on E: Exception do
        begin
          {$IFDEF DEBUG}
          DebugLog('map_get_info EXCEPTION: ' + E.Message);
          {$ENDIF}
          StrPLCopy(MapInfoBuffer, 'Error getting map info', SizeOf(MapInfoBuffer) - 1);
        end;
      end;
    finally
      UnlockDLL;
    end;
  end;

  //------------------------------------------------------------------------------
  // ФУНКЦИИ ДЛЯ РАБОТЫ С ПУТЯМИ (ЭКСПОРТИРУЕМЫЕ)
  //------------------------------------------------------------------------------
  function path_create(): double; cdecl;
  var
    Path: PPath;
  begin
    Result := 0.0;
    LockDLL;
    try
      try
        // Выделяем память
        New(Path);
        // Инициализируем поля
        Path^.ID := GeneratePathID;
        Path^.Length := 0;
        Path^.IsValid := True;
        SetLength(Path^.Points, 0);
        // Добавляем в глобальный массив
        if PathCount >= Length(Paths) then
        begin
          SetLength(Paths, Length(Paths) + 10);
        end;
        Paths[PathCount] := Path;
        Inc(PathCount);
        // ДОБАВЛЯЕМ В ХЭШ-ТАБЛИЦУ
        PathHash[GetPathHash(Path^.ID)] := Path;

        // Возвращаем handle
        Result := Path^.ID;
        {$IFDEF DEBUG}
        DebugLog(Format('f_path_create: Path %d created', [Path^.ID]));
        {$ENDIF}
      except
        on E: Exception do
        begin
          {$IFDEF DEBUG}
          DebugLog('f_path_create EXCEPTION: ' + E.Message);
          {$ENDIF}
          if Path <> nil then
          begin
            Dispose(Path);
          end;
          Result := 0.0;
        end;
      end;
    finally
      UnlockDLL;
    end;
  end;

  function path_destroy(pathHandle: double): double; cdecl;
  var
    i, Handle: integer;
    Path, LastPath: PPath;
    hashIdxDel, hashIdxMove: integer;
  begin
    Result := 0.0;
    Handle := Trunc(pathHandle);

    if Handle <= 0 then
    begin
      {$IFDEF DEBUG}
      DebugLog('f_path_destroy: Invalid handle');
      {$ENDIF}
      Exit;
    end;
    LockDLL;
    try
      for i := 0 to PathCount - 1 do
      begin
        if (Paths[i] <> nil) and (Paths[i]^.ID = Handle) then
        begin
          Path := Paths[i];
          try
            hashIdxDel := GetPathHash(Path^.ID);
            if PathHash[hashIdxDel] = Path then
            begin
              PathHash[hashIdxDel] := nil;
            end;
            Path^.IsValid := False;
            SetLength(Path^.Points, 0);
            Dispose(Path);
            Paths[i] := Paths[PathCount - 1];
            Paths[PathCount - 1] := nil;
            if i < PathCount - 1 then
            begin
              LastPath := Paths[i];
              if LastPath <> nil then
              begin
                hashIdxMove := GetPathHash(LastPath^.ID);
                if PathHash[hashIdxMove] = LastPath then
                begin
                  PathHash[hashIdxMove] := Paths[i];
                end;
              end;
            end;
            Dec(PathCount);
            Result := 1.0;
            {$IFDEF DEBUG}
            DebugLog(Format('f_path_destroy: Path %d destroyed', [Handle]));
            {$ENDIF}
          except
            on E: Exception do
            begin
              {$IFDEF DEBUG}
              DebugLog('f_path_destroy EXCEPTION: ' + E.Message);
              {$ENDIF}
              Result := 0.0;
            end;
          end;
          Exit;
        end;
      end;
      {$IFDEF DEBUG}
      DebugLog(Format('f_path_destroy: Path %d not found', [Handle]));
      {$ENDIF}
    finally
      UnlockDLL;
    end;
  end;

  function path_destroy_all(): double; cdecl;
  var
    i: integer;
    hashIdx: integer;
  begin
    LockDLL;
    try
      try
        for i := 0 to PathCount - 1 do
        begin
          if Paths[i] <> nil then
          begin
            hashIdx := GetPathHash(Paths[i]^.ID);
            if PathHash[hashIdx] = Paths[i] then
            begin
              PathHash[hashIdx] := nil;
            end;

            Paths[i]^.IsValid := False;
            SetLength(Paths[i]^.Points, 0);
            Dispose(Paths[i]);
            Paths[i] := nil;
          end;
        end;
        FillChar(PathHash, SizeOf(PathHash), 0);
        PathCount := 0;
        SetLength(Paths, 0);
        Result := 1.0;
        {$IFDEF DEBUG}
        DebugLog('f_path_destroy_all: All paths destroyed, hash table cleared');
        {$ENDIF}
      except
        on E: Exception do
        begin
          {$IFDEF DEBUG}
          DebugLog('f_path_destroy_all EXCEPTION: ' + E.Message);
          {$ENDIF}
          Result := 0.0;
        end;
      end;
    finally
      UnlockDLL;
    end;
  end;

  function path_find(mapHandle, pathHandle, startX, startY, goalX, goalY, allowSolid, ignoreCost: double): double; cdecl;
  var
    Map: PMap;
    Path: PPath;
    sq, sr, gq, gr: integer; // axial координаты
    bAllowSolid, bIgnoreCost: boolean;
    success: boolean;
    offsetStartX, offsetStartY, offsetGoalX, offsetGoalY: integer;
  begin
    Result := -1.0;

    offsetStartX := Trunc(startX);
    offsetStartY := Trunc(startY);
    offsetGoalX := Trunc(goalX);
    offsetGoalY := Trunc(goalY);

    // Конвертируем параметры в Boolean
    bAllowSolid := allowSolid >= 0.5;
    bIgnoreCost := ignoreCost >= 0.5;

    LockDLL;
    try
      try
        // Находим карту
        Map := FindMapByID(Trunc(mapHandle));
        if Map = nil then
        begin
          {$IFDEF DEBUG}
          DebugLog('f_path_find: Map not found');
          {$ENDIF}
          Exit;
        end;

        // Находим путь
        Path := FindPathByID(Trunc(pathHandle));
        if Path = nil then
        begin
          {$IFDEF DEBUG}
          DebugLog('f_path_find: Path not found');
          {$ENDIF}
          Exit;
        end;

        // ОЧИЩАЕМ ПРЕДЫДУЩИЙ ПУТЬ
        Path^.Length := 0;

        // Проверяем offset координаты
        if not IsValidOffsetCoord(Map, offsetStartX, offsetStartY) then
        begin
          {$IFDEF DEBUG}
          DebugLog(Format('f_path_find: Invalid start offset coordinates (%d,%d)', [offsetStartX, offsetStartY]));
          {$ENDIF}
          Exit;
        end;

        if not IsValidOffsetCoord(Map, offsetGoalX, offsetGoalY) then
        begin
          {$IFDEF DEBUG}
          DebugLog(Format('f_path_find: Invalid goal offset coordinates (%d,%d)', [offsetGoalX, offsetGoalY]));
          {$ENDIF}
          Exit;
        end;

        // Проверяем старт = цель
        if (offsetStartX = offsetGoalX) and (offsetStartY = offsetGoalY) then
        begin
          // Конвертируем start offset ’ axial для сохранения
          OffsetToAxial(offsetStartX, offsetStartY, sq, sr);

          Path^.Length := 1;
          if Length(Path^.Points) < 1 then
          begin
            SetLength(Path^.Points, 1);
          end;
          Path^.Points[0].q := sq;
          Path^.Points[0].r := sr;
          Result := 1.0;

          {$IFDEF DEBUG}
          DebugLog('f_path_find: Start equals goal (path length = 1)');
          {$ENDIF}
          Exit;
        end;

        // Конвертируем offset ’ axial для A*
        OffsetToAxial(offsetStartX, offsetStartY, sq, sr);
        OffsetToAxial(offsetGoalX, offsetGoalY, gq, gr);

        {$IFDEF DEBUG}
        DebugLog(
          Format(
          'f_path_find: Offset->Axial: start(%d,%d)->(%d,%d), goal(%d,%d)->(%d,%d)',
          [offsetStartX, offsetStartY, sq, sr, offsetGoalX, offsetGoalY, gq, gr]
          )
          );
        {$ENDIF}

        // ВЫПОЛНЯЕМ ОПТИМИЗИРОВАННЫЙ A* ПОИСК
        success := Internal_FindPath(Map, Path, sq, sr, gq, gr, bAllowSolid, bIgnoreCost);

        if success then
        begin
          Result := Path^.Length;
          {$IFDEF DEBUG}
          DebugLog(
            Format(
            'A* path found: %d points (AllowSolid=%s, IgnoreCost=%s)',
            [Path^.Length, BoolToStr(bAllowSolid, True), BoolToStr(bIgnoreCost, True)]
            )
            );
          {$ENDIF}
        end
        else
        begin
          Result := 0.0; // Путь не найден
          {$IFDEF DEBUG}
          DebugLog(
            Format('A* path not found (AllowSolid=%s, IgnoreCost=%s)', [BoolToStr(bAllowSolid, True), BoolToStr(bIgnoreCost, True)]));
          {$ENDIF}
        end;

      except
        on E: Exception do
        begin
          {$IFDEF DEBUG}
          DebugLog('f_path_find EXCEPTION: ' + E.Message);
          {$ENDIF}
          Result := -1.0;
        end;
      end;
    finally
      UnlockDLL;
    end;
  end;

  function path_get_length(pathHandle: double): double; cdecl;
  var
    Path: PPath;
  begin
    Result := -1.0; // По умолчанию - ошибка
    LockDLL;
    try
      try
        Path := FindPathByID(Trunc(pathHandle));
        if Path = nil then
        begin
          {$IFDEF DEBUG}
          DebugLog('f_path_get_length: Path not found');
          {$ENDIF}
          Exit;
        end;
        Result := Path^.Length;
      except
        on E: Exception do
        begin
          {$IFDEF DEBUG}
          DebugLog('f_path_get_length EXCEPTION: ' + E.Message);
          {$ENDIF}
          Result := -1.0;
        end;
      end;
    finally
      UnlockDLL;
    end;
  end;

  function path_get_point_q(pathHandle, index: double): double; cdecl;
  var
    Path: PPath;
    idx: integer;
    axialQ, axialR: integer;
    offsetX, offsetY: integer;
  begin
    Result := -1.0;
    idx := Trunc(index);

    LockDLL;
    try
      try
        Path := FindPathByID(Trunc(pathHandle));
        if Path = nil then
        begin
          {$IFDEF DEBUG}
          DebugLog('f_path_get_point_q: Path not found');
          {$ENDIF}
          Exit;
        end;

        if (idx < 0) or (idx >= Path^.Length) then
        begin
          {$IFDEF DEBUG}
          DebugLog(Format('f_path_get_point_q: Index %d out of range [0..%d]', [idx, Path^.Length - 1]));
          {$ENDIF}
          Exit;
        end;

        // Получаем axial координаты
        axialQ := Path^.Points[idx].q;
        axialR := Path^.Points[idx].r;

        // Конвертируем axial ’ offset
        AxialToOffset(axialQ, axialR, offsetX, offsetY);

        // Возвращаем offset X
        Result := offsetX;

      except
        on E: Exception do
        begin
          {$IFDEF DEBUG}
          DebugLog('f_path_get_point_q EXCEPTION: ' + E.Message);
          {$ENDIF}
          Result := -1.0;
        end;
      end;
    finally
      UnlockDLL;
    end;
  end;

  function path_get_point_r(pathHandle, index: double): double; cdecl;
  var
    Path: PPath;
    idx: integer;
    axialQ, axialR: integer;
    offsetX, offsetY: integer;
  begin
    Result := -1.0;
    idx := Trunc(index);

    LockDLL;
    try
      try
        Path := FindPathByID(Trunc(pathHandle));
        if Path = nil then
        begin
          {$IFDEF DEBUG}
          DebugLog('f_path_get_point_r: Path not found');
          {$ENDIF}
          Exit;
        end;

        if (idx < 0) or (idx >= Path^.Length) then
        begin
          {$IFDEF DEBUG}
          DebugLog(Format('f_path_get_point_r: Index %d out of range [0..%d]', [idx, Path^.Length - 1]));
          {$ENDIF}
          Exit;
        end;

        // Получаем axial координаты
        axialQ := Path^.Points[idx].q;
        axialR := Path^.Points[idx].r;

        // Конвертируем axial ’ offset
        AxialToOffset(axialQ, axialR, offsetX, offsetY);

        // Возвращаем offset Y
        Result := offsetY;

      except
        on E: Exception do
        begin
          {$IFDEF DEBUG}
          DebugLog('f_path_get_point_r EXCEPTION: ' + E.Message);
          {$ENDIF}
          Result := -1.0;
        end;
      end;
    finally
      UnlockDLL;
    end;
  end;

  function map_width(mapHandle: double): double; cdecl;
  var
    Map: PMap;
  begin
    Map := FindMapByID(Trunc(mapHandle));
    if Map = nil then
    begin
      Result := 0.0;
      Exit;
    end;

    Result := Map^.Width;
  end;

  function map_height(mapHandle: double): double; cdecl;
  var
    Map: PMap;
  begin
    Map := FindMapByID(Trunc(mapHandle));
    if Map = nil then
    begin
      Result := 0.0;
      Exit;
    end;

    Result := Map^.Height;
  end;

  function map_fill(mapHandle, Value: double): double; cdecl;
  var
    Map: PMap;
    i, mapSize, v: integer;
  begin
    Map := FindMapByID(Trunc(mapHandle));
    if Map = nil then
    begin
      Result := 0.0;
      Exit;
    end;

    v := Trunc(Value);
    mapSize := Map^.Width * Map^.Height;

    for i := 0 to mapSize - 1 do
    begin
      Map^.Cells[i] := v;
    end;

    Result := 1.0;
  end;

  function map_fill_region(mapHandle, startX, startY, endX, endY, Value: double): double; cdecl;
  var
    Map: PMap;
    x1, y1, x2, y2, x, y, v, idx: integer;
    {$ifdef odd-q}axialQ, axialR: integer;{$ENDIF}
  begin
    Result := 0.0;
    LockDLL;
    try
      try
        Map := FindMapByID(Trunc(mapHandle));
        if Map = nil then
        begin
          {$IFDEF DEBUG}
          DebugLog('map_fill_region: Map not found');
          {$ENDIF}
          Exit;
        end;
        // offset координаты
        x1 := Trunc(startX);
        y1 := Trunc(startY);
        x2 := Trunc(endX);
        y2 := Trunc(endY);
        v := Trunc(Value);
        // нормализация
        if x1 > x2 then
        begin
          x := x1;
          x1 := x2;
          x2 := x;
        end;
        if y1 > y2 then
        begin
          y := y1;
          y1 := y2;
          y2 := y;
        end;
        // обрезка по карте (offset границы)
        if x1 < 0 then
        begin
          x1 := 0;
        end;
        if y1 < 0 then
        begin
          y1 := 0;
        end;
        if x2 >= Map^.Width then
        begin
          x2 := Map^.Width - 1;
        end;
        if y2 >= Map^.Height then
        begin
          y2 := Map^.Height - 1;
        end;
        if (x1 > x2) or (y1 > y2) then
        begin
          {$IFDEF DEBUG}
          DebugLog(Format('map_fill_region: Invalid region (%d,%d)-(%d,%d)', [x1, y1, x2, y2]));
          {$ENDIF}
          Exit;
        end;
        for y := y1 to y2 do
        begin
          for x := x1 to x2 do
          begin
            {$ifdef odd-q}
            // offset ’ axial для GetCellIndex
            OffsetToAxial(x, y, axialQ, axialR);
            idx := GetCellIndex(Map, axialQ, axialR);
            {$else}
            idx := y * Map^.Width + x;
            {$endif}
            Map^.Cells[idx] := v;
          end;
        end;

        Result := 1.0;

        {$IFDEF DEBUG}
        DebugLog(Format('map_fill_region: Filled region (%d,%d)-(%d,%d) with value %d', [x1, y1, x2, y2, v]));
        {$ENDIF}

      except
        on E: Exception do
        begin
          {$IFDEF DEBUG}
          DebugLog('map_fill_region EXCEPTION: ' + E.Message);
          {$ENDIF}
          Result := 0.0;
        end;
      end;
    finally
      UnlockDLL;
    end;
  end;

  {$IFDEF DEBUG}
  //------------------------------------------------------------------------------
  // ОТЛАДОЧНЫЕ ФУНКЦИИ
  //------------------------------------------------------------------------------

  function debug_get_status(): PAnsiChar; cdecl;
  var
    InfoStr: AnsiString;
  begin
    LockDLL;
    try
      try
        InfoStr :=
          AnsiString(
          Format('Maps: %d, Paths: %d, NextMapID: %d, NextPathID: %d', [MapCount, PathCount, NextMapID, NextPathID])
          );

        // Копируем в глобальный буфер
        StrPLCopy(InfoBuffer, InfoStr, SizeOf(InfoBuffer) - 1);
        Result := @InfoBuffer[0];

      except
        on E: Exception do
        begin
          DebugLog('debug_get_status EXCEPTION: ' + E.Message);
          StrPLCopy(InfoBuffer, 'Error getting status', SizeOf(InfoBuffer) - 1);
          Result := @InfoBuffer[0];
        end;
      end;
    finally
      UnlockDLL;
    end;
  end;
  {$ENDIF}

  procedure InitializeDLL;
  begin
    InitializeCriticalSection(CS);

    // Инициализация массивов
    SetLength(Maps, 0);
    SetLength(Paths, 0);
    MapCount := 0;
    PathCount := 0;
    NextMapID := 1;
    NextPathID := 1;

    // ИНИЦИАЛИЗАЦИЯ ХЭШ-ТАБЛИЦ
    FillChar(MapHash, SizeOf(MapHash), 0);
    FillChar(PathHash, SizeOf(PathHash), 0);

    {$IFDEF DEBUG}
    DebugLog('=== HexAStar DLL Initialized ===');
    DebugLog('Hexagonal A* Pathfinding with Binary Heap and Hash Tables');
    {$ENDIF}
  end;

  // Очистка при выгрузке DLL
  procedure FinalizeDLL;
  var
    i: integer;
  begin
    {$IFDEF DEBUG}
    DebugLog('=== HexAStar DLL Finalization ===');
    {$ENDIF}
    LockDLL;
    try
      // Уничтожаем все карты
      for i := 0 to MapCount - 1 do
      begin
        if Maps[i] <> nil then
        begin
          // Очищаем хэш-таблицу
          MapHash[GetMapHash(Maps[i]^.ID)] := nil;

          Maps[i]^.IsValid := False;
          SetLength(Maps[i]^.Cells, 0);
          Dispose(Maps[i]);
        end;
      end;
      // Уничтожаем все пути
      for i := 0 to PathCount - 1 do
      begin
        if Paths[i] <> nil then
        begin
          // Очищаем хэш-таблицу
          PathHash[GetPathHash(Paths[i]^.ID)] := nil;
          Paths[i]^.IsValid := False;
          SetLength(Paths[i]^.Points, 0);
          Dispose(Paths[i]);
        end;
      end;
      // Освобождаем массивы
      SetLength(Maps, 0);
      SetLength(Paths, 0);
      {$IFDEF DEBUG}
      DebugLog('All resources freed, hash tables cleared');
      {$ENDIF}
    finally
      UnlockDLL;
      DeleteCriticalSection(CS);
    end;
    {$IFDEF DEBUG}
    DebugLog('=== HexAStar DLL Unloaded ===');
    {$ENDIF}
  end;

  {$IFNDEF fpc}
  // Процедура, вызываемая при выгрузке DLL

  procedure DLLUnloadHandler(Reason: Integer); stdcall;
  begin
    if Reason = DLL_PROCESS_DETACH then
    begin
      FinalizeDLL;
    end;
  end;
  {$endif}

exports
  // Функции карт
  map_create,
  map_destroy,
  map_destroy_all,
  map_set_cell,
  map_get_cell,
  map_get_info,
  map_width,
  map_height,
  map_fill,
  map_fill_region,
  // Функции путей
  path_create,
  path_destroy,
  path_destroy_all,
  path_find,
  path_get_length,
  path_get_point_q,
  path_get_point_r
  {$IFDEF DEBUG}
  ,
  // Отладка
  debug_get_status
  {$ENDIF}
  ;

  {$IFDEF  fpc}
  //------------------------------------------------------------------------------
  // ТОЧКА ВХОДА DLL
  //------------------------------------------------------------------------------

initialization
  InitializeDLL;
finalization
  FinalizeDLL;

  {$else}begin
  InitializeDLL;
  DllProc := @DLLUnloadHandler;
  {$endif}
end.
