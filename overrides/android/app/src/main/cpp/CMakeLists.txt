cmake_minimum_required(VERSION 3.22.1)
project("alpine_runner")

add_library(proot_launcher SHARED proot_launcher.c)

target_include_directories(proot_launcher PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(proot_launcher)