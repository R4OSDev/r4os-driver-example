R4OS Driver Example
===================

Dieses Projekt ist der einfache Startpunkt fuer neue R4D-Treiber in Zig.
Es nutzt Code/System/SDK/r4os statt handgeschriebener Bytecode-Emitter.

Gezeigt wird:
- R4D-init/shutdown-Entries ueber `r4os.r4dev.driverEntriesAsm`
- `r4os.r4dev.DriverApi` und `r4os.r4dev.DriverContext`
- `logInfo`, `logWarn` und `logError`
- Lesen einer optionalen CONFIG.R4S-Option
- DMA-Regionen ueber R4DEV allokieren/freigeben
- PCI-Klasse suchen, BAR lesen und MMIO-BAR mappen
- shared IRQ-Handler registrieren und IRQ-Statistik abfragen
- Rueckkehr aus init und shutdown mit Status 0

Build:

    cd Code
    ..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\zig-out\EXAMPLE.R4D

Im normalen Image liegt die Datei unter:

    C:\R4OS\DRIVERS\EXAMPLE.R4D

Manueller Test in R4OS:

    C:\>LOAD EXAMPLE
    C:\>UNLOAD EXAMPLE

Option fuer lokale Experimente:

    OPTION EXAMPLE mode=manual

Projektstruktur seit 0.51.22
--------------------------------

Dieses Verzeichnis ist ein eigenstaendiges R4OS-SDK-Projekt fuer EXAMPLE.R4D.

Build:

    cd Code\System\Driver\Example
    ..\..\..\DevTools\Zig\zig.exe build

Artefakt:

    zig-out\EXAMPLE.R4D

Manifest:

    module.R4MF

Image-Zielpfad: C:\R4OS\DRIVERS\EXAMPLE.R4D
