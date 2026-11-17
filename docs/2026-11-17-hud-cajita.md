# HUD (la cajita flotante): arreglo del 17-nov-2026

Rama `fix/hud-cajita`, sin commitear. Instalado en /Applications/Loro.app (respaldo del anterior:
`~/.loro-respaldo/Loro.app.bak-2026-11-17`).

## Reproducido con el modo de prueba (antes → después)
`LORO_HUD_DEMO=<carpeta> build/Build/Products/Release/Loro.app/Contents/MacOS/Loro` mueve el estado del
HUD sin hotkey, micrófono ni pegado, y deja capturas + `informe.txt`.

| Caso | Antes | Después |
|---|---|---|
| Texto en vivo de más de 2 líneas | panel clavado en 520x56, texto cortado arriba y abajo | panel 520x132, sigue al contenido |
| Aviso (flash) sobre un dictado que espera Enter | la cajita se iba a los 2,5 s y Enter seguía capturado | la cajita sigue |
| Aviso solo ("El motor todavía no está listo") | decía "Listo" + la pista de la tecla, nunca el mensaje | muestra el mensaje |

Causa del primero: `NSHostingView.fittingSize` devolvía 0 con `sizingOptions = [.preferredContentSize]`.
Ahora el tamaño lo informa SwiftUI (`.fixedSize()` + `onGeometryChange` → `HUDController.contentSizeChanged`).
Causa de los otros: `show()/hide()/flash()` repartidos en ~12 lugares; ahora la visibilidad se deriva del
estado (`AppState.hudVisible`, regla pura `HUDRule.visible`) y `flash` solo pone un mensaje que vence.

## Arreglado por lectura de código (no reproducido en vivo)
- Segundo toque mientras el micrófono abre: fallaba y escondía la cajita del primero (`startRecording` ahora lo ignora).
- Híbrido: presión larga soltada antes de que abriera el micrófono contaba como toque y quedaba pegado en
  "Escuchando…" (`HUDRule.keepsRecordingAfterEarlyRelease`). El botón del menú conserva su comportamiento.
- La posición guardada (`hudAnchor`) se pisaba con cualquier movimiento de la ventana, incluidos los que hace
  macOS al cambiar de monitor; ahora solo tras un arrastre real. Arrastrarla mientras crece ya no la devuelve.
- Mismo error de micrófono dos veces seguidas: el segundo no avisaba.

## Pendiente / conocido
- Dictado vacío o de menos de 0,5 s: la cajita se va sin decir nada (decisión de copy, sin tocar).
- Segundo toque durante la apertura del micrófono se pierde (igual que antes).
- Nido tiene su propia copia de la lógica híbrida (`~/Nido/App/Sources/Assistant/Dictation.swift`), sin tocar.
- Logs nuevos a nivel notice (persisten): `log show --predicate 'subsystem == "cl.manulit0.loro"' | grep HUD`.
