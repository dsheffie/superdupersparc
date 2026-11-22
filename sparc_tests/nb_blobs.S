/* nb_boot.c's NetBSD images (made by nb_boot.sh from the disk image) */
	.section .rodata
	.align	8
	.globl	nb_bootxx, nb_bootxx_end, nb_boot_blocks, nb_boot_blocks_end
nb_bootxx:
	.incbin	"build/nb_bootxx.bin"
nb_bootxx_end:
	.align	8
nb_boot_blocks:
	.incbin	"build/nb_boot_blocks.bin"
nb_boot_blocks_end:
	.section .note.GNU-stack,"",@progbits
