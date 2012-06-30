.text
.global MEMIMAGE
.global MEMIMAGE_END

.macro include filename
.incbin "\filename"
.endm

MEMIMAGE:
include IMAGEFILE
MEMIMAGE_END:
.previous
