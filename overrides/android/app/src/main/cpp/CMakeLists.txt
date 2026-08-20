cmake_minimum_required(VERSION 3.10)
project("alpine_runner")

add_library(proot_launcher SHARED proot_launcher.c)

find_library(log-lib log)

target_include_directories(proot_launcher PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
# log-lib: cần cho __android_log_print() dùng khi debug (logCallback == null
# hoặc thiếu method onLog) - thiếu dòng này sẽ lỗi "undefined reference to
# __android_log_print" lúc link.
target_link_libraries(proot_launcher ${log-lib})