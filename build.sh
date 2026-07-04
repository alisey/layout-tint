#!/bin/sh
set -e

APP="LayoutTint.app"

swiftc -O LayoutTint.swift -o LayoutTint
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp Info.plist "$APP/Contents/"
cp LayoutTint "$APP/Contents/MacOS/"
cp LayoutTint.icns "$APP/Contents/Resources/"

echo "Built $APP"
