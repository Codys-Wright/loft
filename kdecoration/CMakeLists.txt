# Loft's KWin decoration (dev.loft.decoration): macOS Tahoe's title bar,
# light or dark with Loft's theme (<state>/current/kdecoration.ini).
# Built by the flake (nix/packages.nix: loft-kdecoration); docs/KWIN.md §4.4.
cmake_minimum_required(VERSION 3.22)
project(loft-kdecoration LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.6 REQUIRED COMPONENTS Core Gui DBus)
find_package(KF6CoreAddons REQUIRED)
find_package(KDecoration3 REQUIRED)

# Where KWin looks for decoration plugins, relative to the prefix
# (lib/qt-6/plugins on NixOS, which puts it on QT_PLUGIN_PATH).
set(LOFT_PLUGIN_DIR "lib/qt-6/plugins" CACHE STRING "Qt plugin dir, relative to the install prefix")

add_library(dev.loft.decoration MODULE
    config.cpp
    decoration.cpp
    shell.cpp
)
set_target_properties(dev.loft.decoration PROPERTIES PREFIX "")
target_link_libraries(dev.loft.decoration PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::DBus
    KF6::CoreAddons
    KDecoration3::KDecoration
)
install(TARGETS dev.loft.decoration DESTINATION ${LOFT_PLUGIN_DIR}/org.kde.kdecoration3)

# The INI parser and color/defaults logic, without KWin: `ctest`.
enable_testing()
add_executable(config-test config-test.cpp config.cpp)
target_link_libraries(config-test PRIVATE Qt6::Core Qt6::Gui)
add_test(NAME config-test COMMAND config-test)
