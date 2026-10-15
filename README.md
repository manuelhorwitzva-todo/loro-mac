# Loro 🦜

Dictado por voz para macOS, 100% local y gratis. Mantienes una tecla, hablas (en español,
inglés o mezclado), sueltas, y el texto aparece donde tenías el cursor. También transcribe
archivos de audio y video arrastrándolos a una ventana.

Nada sale de tu Mac: ni el audio, ni el texto.

## Requisitos

- macOS 26 (Tahoe) en Apple Silicon.
- Xcode 26 y `brew install xcodegen` para compilar.

## Cómo se usa

```sh
make install     # compila en Release y deja Loro en /Applications
```

Para firmar con tu cuenta de Apple, pon tu Team ID en un archivo `.team` en la raíz
(`echo TU_TEAM_ID > .team`). Sin él se firma ad-hoc: funciona igual, pero macOS puede volver a
pedir Accesibilidad después de cada build.

La primera vez:
1. Acepta el permiso de **Micrófono**.
2. Concede **Accesibilidad** (Ajustes → Privacidad y seguridad → Accesibilidad). Sin esto no
   hay atajo global ni pegado automático; el texto queda igual en el portapapeles.
3. El motor por default (Apple Speech) no descarga nada grande. Si eliges Parakeet o Whisper,
   espera su descarga (~470–630 MB, una sola vez). El estado se ve en el menú.

Después: mantén **⌥ Option derecho**, habla, suelta. `Esc` cancela. Todo se cambia en Ajustes.
La ventana principal se abre desde el lorito de la barra o abriendo Loro de nuevo (Spotlight).

## Diccionario

Ningún motor acepta vocabulario propio de forma confiable, así que el diccionario es una pasada de
corrección sobre el texto: nombres con su forma exacta (GitHub, TestFlight, tu empresa) y correcciones
"cuando escuche X escribe Y" (cloud code → Claude Code). Palabra completa, sin distinguir
mayúsculas ni tildes. Vive en `~/Library/Application Support/Loro/dictionary.json`. Tests: `cd Packages/LoroCore && swift test`.

## Arquitectura

```
Packages/LoroCore/          Swift Package, sin UI. Se prueba desde la terminal.
  Audio.swift               Un solo formato interno: 16 kHz mono Float32. Lee cualquier archivo.
  MicRecorder.swift         Captura del micrófono → ese mismo formato.
  TranscriptionEngine.swift Protocolo. La app no sabe qué motor hay detrás.
  WhisperEngine.swift       WhisperKit (CoreML, Neural Engine). Multilingüe, auto-detecta idioma.
  ParakeetEngine.swift      NVIDIA Parakeet v3 vía FluidAudio. ~8x más rápido que Whisper.
  AppleSpeechEngine.swift   SpeechAnalyzer de Apple. Sin descargas, un idioma por dictado.
  FillerFilter.swift        Quita sonidos de duda (eh, um, ehm). Reglas fijas, sin modelo.
  LanguageDrift.swift       Detecta cuando Parakeet se desvía al inglés/italiano → Whisper.
  Dictionary.swift          Diccionario personal: nombres y correcciones, post-transcripción.
  SpeechSegmenter.swift     Detector de pausas para el preview en vivo.
  Sources/loro/             CLI: `loro transcribe`, `loro bench`, `loro preview`.
App/                        La app de barra de menú (SwiftUI + AppKit donde hace falta).
  AppState.swift            Estado central: motores, grabación, historial, cola de archivos.
  HotkeyMonitor.swift       CGEventTap global (por eso pide Accesibilidad y va sin sandbox).
  Paster.swift              Inserta vía Accessibility; si no, portapapeles + ⌘V restaurando lo que había.
  HUD.swift                 Pastilla flotante que no roba el foco, con texto en vivo.
  MainWindow.swift          Ventana principal: Inicio (checklist), Archivos, Historial, Diccionario.
project.yml                 Fuente de verdad del proyecto Xcode (xcodegen).
```

Por qué así:
- **Sin sandbox y sin App Store.** Un atajo que funciona con cualquier app al frente y pegar
  donde está el cursor son cosas que el sandbox prohíbe. Se distribuye firmado directo.
- **Tres motores detrás de un protocolo.** Se cambian en Ajustes sin tocar nada más.
- **Sin LLM de pulido.** Se probó Apple Intelligence para limpiar el texto: en 40 de 134 dictados
  reales infló el texto y en 27 respondió la pregunta en vez de transcribirla. Se sacó el 10-sep.

## Comparar motores

`make bench` corre los tres sobre `samples/` (audios sintéticos con `say`). Resultado en un M5 Pro:

| Audio | Whisper large-v3 turbo | Parakeet v3 | Apple Speech (es_CL) |
|---|---|---|---|
| Español (7.9 s) | perfecto · 0.88 s | perfecto · 0.13 s | perfecto · 0.33 s |
| Inglés (6.0 s) | perfecto · 0.62 s | perfecto · 0.08 s | "corderly", "sent" · 0.10 s |
| Mezcla es/en (8.2 s) | perfecto · 0.74 s | "churnrat", "homeboarding" · 0.09 s | "Churra te", "lomboardín fluo" · 0.11 s |
| Español → frase en inglés → español | **se salta la frase en inglés** | perfecto | un idioma por sesión |

Esos audios son sintéticos y engañan. Con **104 dictados reales** (español chileno con términos
en inglés, 57 min, `loro bench` sobre `~/Library/Application Support/Loro/audio`, 10-sep):

| | Apple Speech (es_CL) | Whisper (forzado a es) | Parakeet v3 |
|---|---|---|---|
| Latencia mediana / p90 | **0.21 s / 0.50 s** | 1.23 s / 2.31 s | 0.30 s / 0.96 s |
| Se desvió al inglés | 1 | 1 | **43** |
| Se desvió al italiano | 0 | 0 | **22** |

Apple es el default: rápido, sin descargas, no se desvía y en ningún audio perdió contenido.
Su punto débil es la jerga en inglés (sync → "zinc", merge → "merch", mockup → "moup",
card → "carta", Fable → "Facebook"); las formas inequívocas se corrigen con el diccionario.
Whisper escribe mejor esa jerga, pero es ~5× más lento y a veces pierde texto: con VAD se saltó
el comienzo de un audio de 49 s, y sin VAD perdió frases enteras en ~8 de 104. Parakeet solo sirve
si dictas frases enteras en inglés; cuando se desvía, Loro re-transcribe con Whisper.

Auditoría del 14-sep, **93 dictados con Apple** (44 min), re-transcritos con los tres motores y
cruzados con lo que de verdad se envió (prompts registrados por Rastro):
- Apple es determinista (93/93 idéntico al re-transcribir) y sigue sin perder contenido; Whisper
  devolvió vacío un audio de 19 s y cortó otro de 62 s a la mitad. Latencia Apple: 0,19 s mediana.
- Apple pone punto en las pausas aunque la frase siga, y deja la minúscula ("pero. que sean"):
  61 veces en 37 de 93 dictados. El filtro de muletillas capitalizaba después de todo punto y
  convertía esas pausas en cortes de oración falsos. Ahora respeta la minúscula de Apple.
- En 6 de 93 Apple repite o pega un trozo de palabra ("Uber.ber", "¿cacha?chái", "diciendo
  diciendo"). Viene dentro de un mismo resultado del motor, no de Loro; Whisper no lo tiene.
- 67 de 93 se enviaron tal cual. Lo que se corrigió a mano fue jerga: Dan/Adán → done,
  Carl → card, Prot → prod, Facebook → Fable, "perro" → PR.

Inspiración: el video de Pat Simmons "I Cancelled Wispr Flow & Built This Instead" y su repo
[murmur-youtube](https://github.com/per-simmons/murmur-youtube), de donde vienen las ideas de
insertar el texto por Accessibility y de comparar motores.

## Licencia y créditos

Loro es MIT (ver `LICENSE`). Usa [WhisperKit](https://github.com/argmaxinc/WhisperKit) (MIT),
[FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0) y
[swift-argument-parser](https://github.com/apple/swift-argument-parser) (Apache 2.0). Los modelos
se descargan aparte y tienen su propia licencia: Whisper de OpenAI (MIT) y Parakeet TDT v3 de
NVIDIA (CC-BY-4.0).
