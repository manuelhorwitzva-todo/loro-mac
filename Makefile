# Loro — comandos del día a día
APP      = build/Build/Products/Release/Loro.app
PROJECT  = Loro.xcodeproj
# Tu Team ID de Apple va en el archivo .team (no se sube al repo). Sin él, se firma ad-hoc:
# la app funciona en tu Mac, pero macOS puede volver a pedir Accesibilidad tras cada build.
TEAM    := $(shell cat .team 2>/dev/null)
SIGNING  = $(if $(TEAM),DEVELOPMENT_TEAM=$(TEAM),CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)

.PHONY: project build run install cli bench icon clean

project:            ## Regenera Loro.xcodeproj desde project.yml
	xcodegen generate

build: project      ## Compila la app (Release)
	xcodebuild -project $(PROJECT) -scheme Loro -configuration Release -derivedDataPath build -destination "platform=macOS,arch=arm64" ARCHS=arm64 $(SIGNING) build 2>&1 | grep -E "error:|BUILD"

run: build          ## Compila y abre la app
	open $(APP)

install: build      ## Copia la app a /Applications (cierra la anterior si está corriendo)
	-pkill -x Loro
	rm -rf /Applications/Loro.app
	cp -R $(APP) /Applications/Loro.app
	sleep 1
	open /Applications/Loro.app

cli:                ## Compila el CLI `loro` (Packages/LoroCore/.build/release/loro)
	cd Packages/LoroCore && swift build -c release

bench: cli          ## Compara ambos motores con los audios de muestra
	Packages/LoroCore/.build/release/loro bench samples/es.wav samples/en.wav samples/mix.wav

icon:               ## Regenera el ícono (App/Resources/Assets.xcassets)
	swift scripts/make-icon.swift

clean:
	rm -rf build Packages/LoroCore/.build
