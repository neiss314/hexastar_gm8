#define f_define_hexastar_functions
// Инициализация библиотеки - загружает DLL и определяет все внутренние функции
// Должна вызываться один раз в начале программы перед использованием других функций
dll = "hexastar.dll";

// Внутренние определения функций DLL (не вызываются напрямую)
global._1  = external_define(dll, "map_create",        dll_cdecl, ty_real, 2, ty_real, ty_real);
global._2  = external_define(dll, "map_destroy",       dll_cdecl, ty_real, 1, ty_real);
global._3  = external_define(dll, "map_destroy_all",   dll_cdecl, ty_real, 0);

global._4  = external_define(dll, "map_set_cell",      dll_cdecl, ty_real, 4, ty_real, ty_real, ty_real, ty_real);
global._5  = external_define(dll, "map_get_cell",      dll_cdecl, ty_real, 3, ty_real, ty_real, ty_real);
global._6  = external_define(dll, "map_width",         dll_cdecl, ty_real, 1, ty_real);
global._7  = external_define(dll, "map_height",        dll_cdecl, ty_real, 1, ty_real);
global._8  = external_define(dll, "map_fill",          dll_cdecl, ty_real, 2, ty_real, ty_real);
global._9  = external_define(dll, "map_fill_region",   dll_cdecl, ty_real, 6, ty_real, ty_real, ty_real, ty_real, ty_real, ty_real);

global._10 = external_define(dll, "path_create",       dll_cdecl, ty_real, 0);
global._11 = external_define(dll, "path_destroy",      dll_cdecl, ty_real, 1, ty_real);
global._12 = external_define(dll, "path_destroy_all",  dll_cdecl, ty_real, 0);
global._13 = external_define(dll, "path_find",         dll_cdecl, ty_real, 8, ty_real, ty_real, ty_real, ty_real, ty_real, ty_real, ty_real, ty_real);
global._14 = external_define(dll, "path_get_length",   dll_cdecl, ty_real, 1, ty_real);
global._15 = external_define(dll, "path_get_point_q",  dll_cdecl, ty_real, 2, ty_real, ty_real);
global._16 = external_define(dll, "path_get_point_r",  dll_cdecl, ty_real, 2, ty_real, ty_real);
//global._17 = external_define(dll, "map_get_info",      dll_cdecl, ty_string, 1, ty_real);

#define f_map_create
// Создает новую гексагональную карту с заданными размерами
// argument0 - ширина карты (координата q)
// argument1 - высота карты (координата r)
// Возвращает дескриптор карты (положительное число) или 0 при ошибке

return external_call(global._1, argument0, argument1);

#define f_map_destroy
// Удаляет карту и освобождает выделенную память
// argument0 - дескриптор карты для удаления
// Возвращает 1.0 при успехе, 0.0 при ошибке

return external_call(global._2, argument0);

#define f_map_destroy_all
// Удаляет все созданные карты из памяти
// Полезно при смене уровня игры
// Возвращает 1.0 при успехе

return external_call(global._3);

#define f_map_width
// Возвращает ширину карты в гексах (ось q)
// argument0 - дескриптор карты
// Возвращает ширину карты или -1.0 при ошибке

return external_call(global._6, argument0);

#define f_map_height
// Возвращает высоту карты в гексах (ось r)
// argument0 - дескриптор карты
// Возвращает высоту карты или -1.0 при ошибке

return external_call(global._7, argument0);

#define f_set_cell
// Устанавливает стоимость прохождения для конкретной ячейки карты
// argument0 - дескриптор карты
// argument1 - координата q ячейки
// argument2 - координата r ячейки
// argument3 - стоимость прохождения:
//   < 0.0 - непроходимая стена
//   = 0.0 - бесплатный проход
//   = 1.0 - стандартная стоимость
// Возвращает 1.0 при успехе, 0.0 при ошибке

return external_call(global._4, argument0, argument1, argument2, argument3);

#define f_get_cell
// Получает стоимость прохождения для конкретной ячейки карты
// argument0 - дескриптор карты
// argument1 - координата q ячейки
// argument2 - координата r ячейки
// Возвращает стоимость ячейки или -1.0 при ошибке

return external_call(global._5, argument0, argument1, argument2);

#define f_map_fill
// Заполняет всю карту указанным значением стоимости
// argument0 - дескриптор карты
// argument1 - значение стоимости для всех ячеек
// Возвращает 1.0 при успехе, 0.0 при ошибке

return external_call(global._8, argument0, argument1);

#define f_map_fill_region
// Заполняет прямоугольную область карты указанным значением стоимости
// argument0 - дескриптор карты
// argument1 - начальная координата q области (включительно)
// argument2 - начальная координата r области (включительно)
// argument3 - конечная координата q области (включительно)
// argument4 - конечная координата r области (включительно)
// argument5 - значение стоимости для ячеек области
// Возвращает 1.0 при успехе, 0.0 при ошибке

return external_call(global._9, argument0, argument1, argument2, argument3, argument4, argument5);

#define f_path_create
// Создает новый объект для хранения пути
// Возвращает дескриптор пути (положительное число) или 0 при ошибке

return external_call(global._10);

#define f_path_destroy
// Удаляет объект пути и освобождает выделенную память
// argument0 - дескриптор пути для удаления
// Возвращает 1.0 при успехе, 0.0 при ошибке

return external_call(global._11, argument0);

#define f_path_destroy_all
// Удаляет все созданные пути из памяти
// Полезно при смене уровня игры
// Возвращает 1.0 при успехе

return external_call(global._12);

#define f_path_find
// Выполняет поиск пути по алгоритму A* на гексагональной сетке
// argument0 - дескриптор карты для поиска
// argument1 - дескриптор пути для сохранения результата
// argument2 - координата q начального гекса
// argument3 - координата r начального гекса
// argument4 - координата q целевого гекса
// argument5 - координата r целевого гекса
// argument6 - разрешить проход через стены (>=1 - разрешить, <0 - запретить)
// argument7 - игнорировать стоимость ячеек (>=1 - игнорировать, <0 - учитывать)
// Возвращает длину найденного пути (>0.0), 0.0 если путь не найден, или -1.0 при ошибке

return external_call(global._13, argument0, argument1, argument2, argument3, argument4, argument5, argument6, argument7);

#define f_path_length
// Возвращает количество точек в сохраненном пути
// argument0 - дескриптор пути
// Возвращает длину пути (количество точек) или -1.0 при ошибке

return external_call(global._14, argument0);

#define f_path_point_q
// Возвращает координату q точки пути по указанному индексу
// argument0 - дескриптор пути
// argument1 - индекс точки в пути (от 0 до длина_пути-1)
// Возвращает координату q точки или -1.0 при ошибке

return external_call(global._15, argument0, argument1);

#define f_path_point_r
// Возвращает координату r точки пути по указанному индексу
// argument0 - дескриптор пути
// argument1 - индекс точки в пути (от 0 до длина_пути-1)
// Возвращает координату r точки или -1.0 при ошибке

return external_call(global._16, argument0, argument1);

#define f_map_get_info
// Функция получения информации о карте в виде строки
// В текущей версии библиотеки эта функция закомментирована и недоступна
// argument0 - дескриптор карты
// Возвращает строку с информацией о карте

//return external_call(global._17, argument0);