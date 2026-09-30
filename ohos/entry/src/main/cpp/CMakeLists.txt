cmake_minimum_required(VERSION 3.5.0)
project(qfli_jdk_layout)
add_library(qfli_jdk_layout SHARED jdk_layout.cpp jdk_process.cpp)
target_link_libraries(qfli_jdk_layout PUBLIC libace_napi.z.so)
