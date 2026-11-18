cmake_minimum_required(VERSION 3.16)
project({{PROJECT_NAME}} LANGUAGES C CXX)

add_executable(${PROJECT_NAME}
    main.cpp
    hello_c.c
)
