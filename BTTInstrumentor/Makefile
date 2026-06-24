install:
	swift build -c release --product BTTInstrumentor --triple arm64-apple-macosx
	swift build -c release --product BTTInstrumentor --triple x86_64-apple-macosx
	lipo -create -output .build/release/BTTInstrumentor \
		.build/arm64-apple-macosx/release/BTTInstrumentor \
		.build/x86_64-apple-macosx/release/BTTInstrumentor
	strip -rSTX .build/release/BTTInstrumentor
	sudo cp .build/release/BTTInstrumentor /usr/local/bin/BTTInstrumentor
