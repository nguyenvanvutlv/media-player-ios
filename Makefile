TOP_DIR        := /Users/admin/Desktop/work/media-player-ios/build/_deps-work/ios-sim-arm64/freetype-src
OBJ_DIR        := /Users/admin/Desktop/work/media-player-ios
OBJ_BUILD      := $(OBJ_DIR)
DOC_DIR        := $(OBJ_DIR)/docs
FT_LIBTOOL_DIR := $(OBJ_DIR)
ifndef FT2DEMOS
  include $(TOP_DIR)/Makefile
else
  TOP_DIR_2 := $(TOP_DIR)/../ft2demos
  PROJECT   := freetype
  CONFIG_MK := $(OBJ_DIR)/config.mk
  include $(TOP_DIR_2)/Makefile
endif
