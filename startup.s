.section .text
.global _start

_start:
    li sp, 0x400
    call main

halt:
    j halt
