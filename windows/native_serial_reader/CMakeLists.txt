cmake_minimum_required(VERSION 3.14)
project(native_serial_reader LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 定义 DLL 目标
add_library(native_serial_reader SHARED
  native_serial_reader.cpp
  native_serial_reader.h
  dart_api_dl.c
)

target_compile_definitions(native_serial_reader PRIVATE NATIVE_SERIAL_READER_EXPORTS)

# 链接 Windows 库
target_link_libraries(native_serial_reader PRIVATE
  kernel32
  user32
)

# 设置输出目录到 runner 的构建目录
set_target_properties(native_serial_reader PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/runner/$<CONFIG>"
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/runner/$<CONFIG>"
  ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/runner/$<CONFIG>"
)
