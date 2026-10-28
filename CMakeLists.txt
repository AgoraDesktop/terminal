# Terminal — Agora's terminal application.
#
# An APPLICATION, so it consumes the AppKit as a built package (`AgoraApp::App`) and installs no library of its own.
# The emulation is libtsm's (`tsm::tsm`, the kmscon state machine, MIT): what lives in this repository is the paint,
# the window, and the process — see README.md for the division and tests/terminal_draw.m for what is proven.
cmake_minimum_required(VERSION 3.24)

project(AgoraTerminal VERSION 0.1.0 LANGUAGES C OBJC)

include(GNUInstallDirs)

set(CMAKE_POSITION_INDEPENDENT_CODE YES)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

find_package(AgoraApp CONFIG REQUIRED)
find_package(tsm CONFIG REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(XKBCOMMON REQUIRED IMPORTED_TARGET xkbcommon)

# The part that has no window in it: the emulator's grid and the paint. Both the application and the headless probe
# are built from this list, so the probe tests the same object files the window runs.
set(TERMINAL_CORE
    src/AGTerminalGrid.m
    src/AGTerminalRenderer.m)

add_executable(Terminal
    src/main.m
    src/AGTerminalSession.m
    src/AGTerminalView.m
    ${TERMINAL_CORE})

target_include_directories(Terminal PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_link_libraries(Terminal PRIVATE AgoraApp::App tsm::tsm)

# ---------------------------------------------------------------------------
# The bundle: Terminal.app/Contents/{Info.plist, <platform>/<arch>/Terminal}
# ---------------------------------------------------------------------------
# The directory names are libagora-core's resolver vocabulary, not CMake's — a bundle laid out with CMake's `x86_64`
# is one this tree cannot launch, and it would say so only at run time.
if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
  set(_bundle_platform "MacOS")
elseif(CMAKE_SYSTEM_NAME MATCHES "^(Linux|FreeBSD|NetBSD|OpenBSD|DragonFly)$")
  set(_bundle_platform "${CMAKE_SYSTEM_NAME}")
else()
  message(FATAL_ERROR "Terminal: no bundle platform directory is named for ${CMAKE_SYSTEM_NAME}.")
endif()

if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|amd64|AMD64)$")
  set(_bundle_arch "amd64")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64|ARM64)$")
  set(_bundle_arch "arm64")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^riscv64$")
  set(_bundle_arch "riscv64")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(i[3-6]86|x86)$")
  set(_bundle_arch "i386")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(ppc64|ppc64le|powerpc64)$")
  set(_bundle_arch "ppc64")
else()
  message(FATAL_ERROR "Terminal: no bundle architecture directory is named for ${CMAKE_SYSTEM_PROCESSOR}.")
endif()

set(_bundle "${CMAKE_BINARY_DIR}/Terminal.app")
configure_file("${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in" "${_bundle}/Contents/Info.plist" @ONLY)
add_custom_command(TARGET Terminal POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory
        "${_bundle}/Contents/${_bundle_platform}/${_bundle_arch}"
    COMMAND ${CMAKE_COMMAND} -E copy "$<TARGET_FILE:Terminal>"
        "${_bundle}/Contents/${_bundle_platform}/${_bundle_arch}/Terminal")

# ---------------------------------------------------------------------------
# The headless probe: bytes in, pixels out, no compositor anywhere
# ---------------------------------------------------------------------------
# It paints into an NSBitmapImageRep, so it runs as an ordinary ctest — the emulator and the renderer are exactly the
# halves that do not need a window, and a pixel assertion is the only honest test of "the right ink landed in the
# right cell".
# **`BUILD_TESTING` HAS TO EXIST BEFORE IT IS ASKED ABOUT**, which `include(CTest)` is what makes true: it defines
# the option (ON when a configure says nothing) and turns testing on with it, so a developer's build runs the tests
# and the release driver's `-DBUILD_TESTING=OFF` builds none of them.
include(CTest)

if(BUILD_TESTING)
  enable_testing()
  add_executable(terminal_draw tests/terminal_draw.m ${TERMINAL_CORE})
  target_include_directories(terminal_draw PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
  target_link_libraries(terminal_draw PRIVATE AgoraApp::App tsm::tsm m)
  add_test(NAME terminal-draw COMMAND terminal_draw)

  # **AND THE OTHER HALF: A REAL SHELL, A REAL PTY, AND WHAT IT PRINTED READ BACK OUT OF THE GRID.** No compositor —
  # the process half is provable on its own, and it is the half whose failures look like "the terminal is hung".
  # **AND THE KEYS, THROUGH THE VIEW INTO A REAL SHELL** — the probe the first live run needed: `Enter` worked and
  # nothing else did, because a view that is not an `NSTextInput` client has no input context to interpret a key with.
  add_executable(terminal_keys tests/terminal_keys.m ${TERMINAL_CORE} src/AGTerminalSession.m src/AGTerminalView.m)
  target_include_directories(terminal_keys PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
  target_link_libraries(terminal_keys PRIVATE AgoraApp::App tsm::tsm m PkgConfig::XKBCOMMON)
  add_test(NAME terminal-keys COMMAND terminal_keys)

  # THE VIEW, THROUGH THE APPKIT'S OWN DISPATCH — see the probe's header for why that is a separate claim.
  add_executable(terminal_view tests/terminal_view.m ${TERMINAL_CORE} src/AGTerminalSession.m src/AGTerminalView.m)
  target_include_directories(terminal_view PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
  target_link_libraries(terminal_view PRIVATE AgoraApp::App tsm::tsm m)
  add_test(NAME terminal-view COMMAND terminal_view)

  add_executable(terminal_session tests/terminal_session.m ${TERMINAL_CORE} src/AGTerminalSession.m)
  target_include_directories(terminal_session PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
  target_link_libraries(terminal_session PRIVATE AgoraApp::App tsm::tsm m)
  # **AND IT RUNS WITHOUT A CONTROLLING TERMINAL**, which is how the application is launched and the only context in
  # which the pty's O_NOCTTY bug was visible. See the runner's own header.
  add_test(NAME terminal-session
	   COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/tests/run-terminal-session.sh" "$<TARGET_FILE:terminal_session>")
endif()

# ---------------------------------------------------------------------------
# Install: the bundle, with an INSTALL_RPATH so it starts with no environment
# ---------------------------------------------------------------------------
set(_bundle_install "${CMAKE_INSTALL_LIBEXECDIR}/Terminal.app")

get_property(_terminal_rpath_is_set CACHE CMAKE_INSTALL_RPATH PROPERTY TYPE SET)
if(NOT _terminal_rpath_is_set)
  set_target_properties(Terminal PROPERTIES
      INSTALL_RPATH "${CMAKE_INSTALL_FULL_LIBDIR}")
endif()

install(TARGETS Terminal
    RUNTIME DESTINATION "${_bundle_install}/Contents/${_bundle_platform}/${_bundle_arch}")
install(FILES "${_bundle}/Contents/Info.plist" DESTINATION "${_bundle_install}/Contents")
