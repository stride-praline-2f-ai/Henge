#!/usr/bin/env python3
"""Typecheck all production Swift files against a real Apple SDK; no packaging."""
import argparse,subprocess
from pathlib import Path
parser=argparse.ArgumentParser()
parser.add_argument('--sdk',required=True,choices=['iphoneos','iphonesimulator'])
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
sdk=subprocess.check_output(['xcrun','--sdk',args.sdk,'--show-sdk-path'],text=True).strip()
files=sorted(str(p.relative_to(root)) for p in (root/'ios/Henge').rglob('*.swift'))
files.append('ios/HengeJITHelper/HengeJITMessages.swift')
target='arm64-apple-ios17.0'+('-simulator' if args.sdk=='iphonesimulator' else '')
subprocess.run(['xcrun','--sdk',args.sdk,'swiftc','-typecheck','-parse-as-library',
               '-swift-version','5','-module-name','Henge','-target',target,'-sdk',sdk,
               '-Xcc','-Icore','-Xcc','-Ihost','-Xcc','-Idevices',
               '-import-objc-header','ios/Henge/HengeBridge.h',*files],cwd=root,check=True)
print('PASS complete app SDK typecheck:',len(files),'production Swift sources;',args.sdk,'no app or IPA built')
