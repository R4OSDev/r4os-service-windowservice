WINSVC.R4X
==========

WINSVC.R4X ist der Window- und Task-State-Service.

Projektstruktur seit 0.51.19:
- `build.zig` baut den Service als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad, Imports, Startdaten und Contract.

Build:

    cd Code\System\Services\WindowService
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Services\WindowService\zig-out\WINSVC.R4X

Contract:
- R4XStart-Entry: `winsvc_main`
- App-Klasse: `service`
- R4L-Imports: `R4SYS`
- Service-Name: `WINSVC`
- Standardargumente: `/RUN`
- Zielpfad im Image: `C:\R4OS\SERVICES\WINSVC.R4X`

