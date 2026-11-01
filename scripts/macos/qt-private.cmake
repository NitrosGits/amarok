# Qt from Homebrew doesn't pull in the private targets automatically; some KF6
# frameworks link Qt6::*Private without a matching find_package.
# Skipped for projects with no languages enabled (e.g. extra-cmake-modules).
if(CMAKE_CXX_COMPILER_LOADED)
  find_package(Qt6 QUIET CONFIG COMPONENTS Core Gui Widgets)
  foreach(c CorePrivate GuiPrivate WidgetsPrivate)
    find_package(Qt6${c} QUIET CONFIG)
  endforeach()
endif()
