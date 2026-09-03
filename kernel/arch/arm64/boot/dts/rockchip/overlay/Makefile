# Device tree overlays for RK3576
#
# Compile all overlay .dts files to .dtbo (device tree blobs for overlay).

DTC := dtc
DTC_FLAGS := -@ -I dts -O dtb

OVERLAY_SRC := $(wildcard *.dts)
OVERLAY_DTBO := $(OVERLAY_SRC:.dts=.dtbo)

all: $(OVERLAY_DTBO)

%.dtbo: %.dts
	$(DTC) $(DTC_FLAGS) -o $@ $<

clean:
	rm -f $(OVERLAY_DTBO)

.PHONY: all clean
