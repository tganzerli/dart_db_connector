cmake_minimum_required(VERSION 3.20)
project(native_db
    VERSION 0.1.0
    DESCRIPTION "C wrapper over libpq with Dart Native Ports for async I/O"
    LANGUAGES C
)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Help find_package(PostgreSQL) locate Homebrew libpq on macOS, which is keg-only.
if(APPLE AND NOT DEFINED PostgreSQL_ROOT)
    foreach(_candidate "/opt/homebrew/opt/libpq" "/usr/local/opt/libpq")
        if(EXISTS "${_candidate}/include/libpq-fe.h")
            set(PostgreSQL_ROOT "${_candidate}" CACHE PATH "Homebrew libpq prefix" FORCE)
            message(STATUS "Detected Homebrew libpq at ${PostgreSQL_ROOT}")
            break()
        endif()
    endforeach()
endif()

find_package(PostgreSQL REQUIRED)
find_package(Threads REQUIRED)

add_library(native_db SHARED
    src/native_db.c
    src/native_pool.c
    src/native_pool_worker.c
    src/dart_api_dl.c
)

target_include_directories(native_db
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include
        # dart_api_dl.c (vendored, do not modify) does `#include "dart_api_dl.h"`
        # without the dart/ prefix; expose include/dart/ directly:
        ${CMAKE_CURRENT_SOURCE_DIR}/include/dart
        ${PostgreSQL_INCLUDE_DIRS}
)

target_link_libraries(native_db
    PRIVATE
        ${PostgreSQL_LIBRARIES}
        Threads::Threads
)

target_compile_options(native_db PRIVATE
    -Wall -Wextra -Wpedantic
)

# Expose POSIX `clock_gettime` / `CLOCK_REALTIME` on Linux glibc
# (visible by default on macOS, but glibc gates them behind a
# feature-test macro). 200809L = POSIX.1-2008.
target_compile_definitions(native_db PRIVATE
    _POSIX_C_SOURCE=200809L
)

# Produces:
#   - libnative_db.dylib (macOS)
#   - libnative_db.so    (Linux)
#   - native_db.dll      (Windows)
# Loaded at runtime by dart/lib/src/native_lib_loader.dart.

# ─────────────────────────────────────────────────────────────────────
# MySQL driver (2026-07-24) — independent native lib
# libnative_mysql over libmysqlclient. Optional: toggle with
# -DBUILD_NATIVE_MYSQL=OFF to build only the PostgreSQL lib (e.g. on a
# host without the MySQL client). Governed by
# the ABI stability policy in CONTRIBUTING.md (new ABI: native_mysql.h).
# ─────────────────────────────────────────────────────────────────────
option(BUILD_NATIVE_MYSQL "Build the MySQL driver native lib" ON)

if(BUILD_NATIVE_MYSQL)
    # Locate mysql_config. Homebrew's mysql-client is keg-only, so its
    # bin/ is not on PATH — hint the common prefixes. On Linux,
    # libmysqlclient-dev / mariadb provide mysql_config on PATH.
    find_program(MYSQL_CONFIG mysql_config
        HINTS
            /opt/homebrew/opt/mysql-client/bin
            /usr/local/opt/mysql-client/bin
        PATHS ENV PATH
    )
    if(NOT MYSQL_CONFIG)
        message(FATAL_ERROR
            "mysql_config not found. Install the MySQL client "
            "(brew install mysql-client / apt install libmysqlclient-dev) "
            "or configure with -DBUILD_NATIVE_MYSQL=OFF.")
    endif()

    execute_process(COMMAND ${MYSQL_CONFIG} --include
        OUTPUT_VARIABLE MYSQL_INCLUDE_RAW OUTPUT_STRIP_TRAILING_WHITESPACE)
    execute_process(COMMAND ${MYSQL_CONFIG} --libs
        OUTPUT_VARIABLE MYSQL_LIBS_RAW OUTPUT_STRIP_TRAILING_WHITESPACE)
    # `--include` may yield multiple "-I/path" flags (e.g. MariaDB Connector/C
    # on Debian returns two). Split into a real list and strip the -I from
    # each, so every dir is added as a separate include path.
    separate_arguments(_mysql_inc_flags UNIX_COMMAND "${MYSQL_INCLUDE_RAW}")
    set(MYSQL_INCLUDE_DIRS "")
    foreach(_flag ${_mysql_inc_flags})
        string(REGEX REPLACE "^-I" "" _dir "${_flag}")
        list(APPEND MYSQL_INCLUDE_DIRS "${_dir}")
    endforeach()
    separate_arguments(MYSQL_LIBS UNIX_COMMAND "${MYSQL_LIBS_RAW}")
    message(STATUS "MySQL client via ${MYSQL_CONFIG}: include=${MYSQL_INCLUDE_DIRS}")

    add_library(native_mysql SHARED
        src/native_mysql.c
        src/mysql_pool.c
        src/mysql_pool_worker.c
        src/dart_api_dl.c
    )

    target_include_directories(native_mysql
        PRIVATE
            ${CMAKE_CURRENT_SOURCE_DIR}/include
            ${CMAKE_CURRENT_SOURCE_DIR}/include/dart
            ${MYSQL_INCLUDE_DIRS}
    )

    # `mysql_config --libs` names transitive deps (-lzstd -lssl -lcrypto)
    # but only adds the mysql-client -L. On macOS those keg-only libs are
    # symlinked under the Homebrew lib dir; add it to the linker search
    # path so the named libraries resolve.
    if(APPLE)
        foreach(_brew_lib "/opt/homebrew/lib" "/usr/local/lib")
            if(EXISTS "${_brew_lib}")
                target_link_directories(native_mysql PRIVATE "${_brew_lib}")
            endif()
        endforeach()
    endif()

    target_link_libraries(native_mysql
        PRIVATE
            ${MYSQL_LIBS}
            Threads::Threads
    )

    target_compile_options(native_mysql PRIVATE
        -Wall -Wextra -Wpedantic
    )

    target_compile_definitions(native_mysql PRIVATE
        _POSIX_C_SOURCE=200809L
    )

    # Produces:
    #   - libnative_mysql.dylib (macOS)
    #   - libnative_mysql.so    (Linux)
    # Loaded at runtime by dart/lib/src/native_lib_loader.dart.
endif()

# ─────────────────────────────────────────────────────────────────────
# MongoDB driver (2026-07-27) — independent native lib
# libnative_mongo over libmongoc (MongoDB C Driver, 2.x). Optional: toggle
# with -DBUILD_NATIVE_MONGO=OFF to skip on a host without libmongoc.
# Governed by the ABI stability policy in CONTRIBUTING.md (new ABI: native_mongo.h).
# ─────────────────────────────────────────────────────────────────────
option(BUILD_NATIVE_MONGO "Build the MongoDB driver native lib" ON)

if(BUILD_NATIVE_MONGO)
    find_package(PkgConfig REQUIRED)
    # Homebrew's mongo-c-driver ships its .pc under its own opt prefix and
    # is not symlinked onto the default pkg-config search path; hint it (plus
    # openssl, a transitive dep). On Linux the distro package is on PATH.
    if(APPLE)
        foreach(_pc "/opt/homebrew/opt/mongo-c-driver/lib/pkgconfig"
                    "/usr/local/opt/mongo-c-driver/lib/pkgconfig"
                    "/opt/homebrew/opt/openssl@3/lib/pkgconfig"
                    "/usr/local/opt/openssl@3/lib/pkgconfig")
            if(EXISTS "${_pc}")
                set(ENV{PKG_CONFIG_PATH} "${_pc}:$ENV{PKG_CONFIG_PATH}")
            endif()
        endforeach()
    endif()

    # mongo-c-driver 2.x exposes the `mongoc2` package (1.x used
    # `libmongoc-1.0`); accept either so the build works on both series.
    pkg_check_modules(MONGOC QUIET mongoc2)
    if(NOT MONGOC_FOUND)
        pkg_check_modules(MONGOC REQUIRED libmongoc-1.0)
    endif()
    message(STATUS "libmongoc via pkg-config: ${MONGOC_VERSION} (include=${MONGOC_INCLUDE_DIRS})")

    add_library(native_mongo SHARED
        src/native_mongo.c
        src/mongo_pool.c
        src/mongo_pool_worker.c
        src/dart_api_dl.c
    )

    target_include_directories(native_mongo
        PRIVATE
            ${CMAKE_CURRENT_SOURCE_DIR}/include
            ${CMAKE_CURRENT_SOURCE_DIR}/include/dart
            ${MONGOC_INCLUDE_DIRS}
    )

    target_link_directories(native_mongo PRIVATE ${MONGOC_LIBRARY_DIRS})

    target_link_libraries(native_mongo
        PRIVATE
            ${MONGOC_LIBRARIES}
            Threads::Threads
    )

    target_compile_options(native_mongo PRIVATE
        -Wall -Wextra -Wpedantic ${MONGOC_CFLAGS_OTHER}
    )

    target_compile_definitions(native_mongo PRIVATE
        _POSIX_C_SOURCE=200809L
    )

    # Produces:
    #   - libnative_mongo.dylib (macOS)
    #   - libnative_mongo.so    (Linux)
    # Loaded at runtime by dart/lib/src/native_lib_loader.dart.
endif()

# ─────────────────────────────────────────────────────────────────────
# SQLite driver (2026-07-27) — independent native lib
# libnative_sqlite over libsqlite3 (EMBEDDED). Optional: toggle with
# -DBUILD_NATIVE_SQLITE=OFF. Governed by the ABI stability policy in CONTRIBUTING.md.
# ─────────────────────────────────────────────────────────────────────
option(BUILD_NATIVE_SQLITE "Build the SQLite driver native lib" ON)

if(BUILD_NATIVE_SQLITE)
    # FindSQLite3 (CMake ≥ 3.14) locates the system lib on macOS (SDK) and
    # libsqlite3-dev on Linux.
    find_package(SQLite3 REQUIRED)
    message(STATUS "libsqlite3 via find_package: ${SQLite3_VERSION}")

    add_library(native_sqlite SHARED
        src/native_sqlite.c
        src/sqlite_pool.c
        src/sqlite_pool_worker.c
        src/dart_api_dl.c
    )

    target_include_directories(native_sqlite
        PRIVATE
            ${CMAKE_CURRENT_SOURCE_DIR}/include
            ${CMAKE_CURRENT_SOURCE_DIR}/include/dart
            ${SQLite3_INCLUDE_DIRS}
    )

    target_link_libraries(native_sqlite
        PRIVATE
            SQLite3::SQLite3
            Threads::Threads
    )

    target_compile_options(native_sqlite PRIVATE
        -Wall -Wextra -Wpedantic
    )

    target_compile_definitions(native_sqlite PRIVATE
        _POSIX_C_SOURCE=200809L
    )

    # Produces:
    #   - libnative_sqlite.dylib (macOS)
    #   - libnative_sqlite.so    (Linux)
    # Loaded at runtime by dart/lib/src/native_lib_loader.dart.
endif()
