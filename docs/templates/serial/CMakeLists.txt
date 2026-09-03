cmake_minimum_required(VERSION 3.16)
project({{PROJECT_NAME}} LANGUAGES C CXX)

file(GLOB APP_SOURCES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/*.c"
    "${CMAKE_CURRENT_SOURCE_DIR}/*.cc"
    "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp")
if(NOT APP_SOURCES)
    message(FATAL_ERROR "No C/C++ sources found")
endif()

add_executable(${PROJECT_NAME} ${APP_SOURCES})
target_compile_options(${PROJECT_NAME} PRIVATE -Wall -Wextra -O2)
find_package(Threads)
if(Threads_FOUND)
    target_link_libraries(${PROJECT_NAME} PRIVATE Threads::Threads)
endif()
