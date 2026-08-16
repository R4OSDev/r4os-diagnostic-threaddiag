THREADD.R4X
===========

THREADD.R4X ist die R4X-Userland-Thread-Diagnose.

Projektstruktur seit 0.53.19:
- `build.zig` baut die Diagnose als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad, R4L-Imports und Contract.

Build:

    cd Code\System\Diagnostics\ThreadDiag
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Diagnostics\ThreadDiag\zig-out\THREADD.R4X

Contract:
- Build-Profil: `Zig/R4XStart`
- R4XStart-Entry: `threadd_main`
- App-Klasse: `console`
- R4L-Imports: `R4SYS`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\TERMINAL\DIAG\THREADD.R4X`

Abnahme:
- `threadCurrent()` liefert fuer den Main-Thread eine gueltige ID.
- `threadStatus()` meldet Main-/Worker-Stack und Thread-Flags.
- Self-Join wird sichtbar als `thread_error_self_join` abgelehnt.
- Ungueltige Flags werden sichtbar als `thread_error_unsupported` abgelehnt.
- Ein normaler Worker wird gestartet, gejoined und danach bereinigt.
- Ein Worker kann sich mit `threadExit()` selbst mit Exitcode beenden.
