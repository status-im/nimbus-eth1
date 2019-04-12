SHELL := bash # the shell used internally by "make"

#- extra parameters for the Nim compiler
#- NIMFLAGS should come from the environment or make's command line
NIM_PARAMS := $(NIMFLAGS)

# verbosity level
V := 0
NIM_PARAMS := $(NIM_PARAMS) --verbosity:$(V)
HANDLE_OUTPUT :=
SILENT_TARGET_PREFIX := disabled
ifeq ($(V), 0)
  NIM_PARAMS := $(NIM_PARAMS) --hints:off --warnings:off
  HANDLE_OUTPUT := &>/dev/null
  SILENT_TARGET_PREFIX :=
endif

# Chronicles log level
LOG_LEVEL :=
ifdef LOG_LEVEL
  NIM_PARAMS := $(NIM_PARAMS) -d:chronicles_log_level=$(LOG_LEVEL)
endif

# guess who does parsing before variable expansion
COMMA := ,
EMPTY :=
SPACE := $(EMPTY) $(EMPTY)

# coloured messages
BUILD_MSG := "\\e[92mBuilding:\\e[39m"

