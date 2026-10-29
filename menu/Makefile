# Menu module for the Maximig core (the A4000/040 and the AA3000+), built with
# Main_MiSTer's menu module SDK: mnu_api.h, mnu_minimig.h and mnu_module.mk.
#
#   make                                     -> Maximig.mnu
#   make deploy MNU_SD_NAME=Maximig_a_aa3000.mnu
#        next to the Maximig_a_aa3000_<date>.rbf files on the card; a module
#        named like the rbf without its date code is found for every date
#   make reload                              -> the running MiSTer reloads it
#
# The SCSI target code is the core's own hps/maximig_scsi_target.h.
MNU_NAME     = Maximig
MAIN_MISTER ?= $(abspath ../../MiSTer_Main/Main_MiSTer)
MNU_SD_DIR  ?= /media/fat
MNU_INCLUDES = -I../hps
include $(MAIN_MISTER)/mnu_module.mk
