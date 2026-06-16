cmake_minimum_required(VERSION 3.14)
project(vscope_updater LANGUAGES CXX)

add_executable(vscope_updater WIN32 updater.cpp)
target_compile_features(vscope_updater PRIVATE cxx_std_17)
target_compile_definitions(vscope_updater PRIVATE UNICODE _UNICODE NOMINMAX)
target_compile_options(vscope_updater PRIVATE /W4 /EHsc)
target_link_libraries(
  vscope_updater PRIVATE bcrypt.lib shell32.lib advapi32.lib userenv.lib)
