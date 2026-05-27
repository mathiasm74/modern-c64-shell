; irq.s - Phase 0 interrupt stubs.
;
; No interrupts are enabled yet (reset leaves IRQs masked), so these handlers
; should never actually fire. They exist only so the NMI and IRQ/BRK hardware
; vectors point at valid code. A real IRQ handler arrives in Phase 3.

.export irq_stub
.export nmi_stub

.segment "CODE"

irq_stub:
nmi_stub:
        rti
