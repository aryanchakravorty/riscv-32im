ENTRY(_start)

SECTIONS {
    . = 0x00000000;
    .text : { *(.text) *(.text.*) *(.rodata) *(.rodata.*) }

    . = 0x00000200;
    .data : { *(.data) *(.data.*) }
    .bss  : { *(.bss) *(.bss.*) *(COMMON) }
}
