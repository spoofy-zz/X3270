cmake_minimum_required(VERSION 3.21)
project(X3270 VERSION 1.0.3 LANGUAGES CXX OBJCXX)

# ── Version / Build number ────────────────────────────────────────────────────
# Override on the command line: cmake -DBUILD_NUMBER=42 ..
set(BUILD_NUMBER "1" CACHE STRING "Monotonically increasing build counter")
set(FULL_VERSION "${PROJECT_VERSION}.${BUILD_NUMBER}")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

# ── Dependencies ─────────────────────────────────────────────────────────────
find_package(OpenSSL REQUIRED)

# ── Sources ───────────────────────────────────────────────────────────────────
set(CORE_SOURCES
    src/core/TLSTransport.cpp
    src/core/TN3270Session.cpp
    src/core/EbcdicCodec.cpp
    src/core/ScreenBuffer.cpp
    src/core/DataStreamParser.cpp
    src/core/KeyboardState.cpp
)

set(UI_SOURCES
    src/ui/main.mm
    src/ui/AppDelegate.mm
    src/ui/ConnectionWindowController.mm
    src/ui/DebugWindowController.mm
    src/ui/TerminalView.mm
    src/ui/TerminalWindowController.mm
    src/ui/PreferencesWindowController.mm
)

# ── App Bundle ────────────────────────────────────────────────────────────────
add_executable(X3270 MACOSX_BUNDLE
    ${CORE_SOURCES}
    ${UI_SOURCES}
)

set_target_properties(X3270 PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/resources/Info.plist"
    MACOSX_BUNDLE_BUNDLE_NAME "X3270"
    MACOSX_BUNDLE_BUNDLE_VERSION "${BUILD_NUMBER}"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.x3270.macos"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.x3270.macos"
)

target_include_directories(X3270 PRIVATE
    src/core
    src/ui
    ${OPENSSL_INCLUDE_DIR}
)

target_link_libraries(X3270 PRIVATE
    OpenSSL::SSL
    OpenSSL::Crypto
    "-framework AppKit"
    "-framework Foundation"
    "-framework CoreText"
    "-framework CoreGraphics"
)

target_compile_options(X3270 PRIVATE
    -Wall
    -Wextra
    -Wno-unused-parameter
)

# ── Compile .mm files as Objective-C++ with ARC ──────────────────────────────
foreach(src_file ${UI_SOURCES})
    set_source_files_properties(${src_file} PROPERTIES
        COMPILE_FLAGS "-x objective-c++ -fobjc-arc"
    )
endforeach()
