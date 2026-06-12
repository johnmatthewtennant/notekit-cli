CC = clang
# Version embedded in the binary. The Homebrew formula passes VERSION=#{version}
# (the release tag); local builds fall back to the latest git tag, then "dev".
VERSION ?= $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo dev)
CFLAGS = -framework Foundation -framework CoreData -framework AppKit -lobjc -O2 -DNOTEKIT_VERSION='"$(VERSION)"'
INFO_PLIST = Info.plist
BUNDLE_ID = com.jtennant.notekit-cli
INFO_PLIST_FLAGS = -Wl,-sectcreate,__TEXT,__info_plist,$(INFO_PLIST)

all: notekit

notekit: notekit.m notekit-version-check.m notekit-generated.m notekit-handwritten.m notekit-tests.m disclaim.c disclaim.h $(INFO_PLIST)
	$(CC) $(CFLAGS) $(INFO_PLIST_FLAGS) notekit.m disclaim.c -o $@
	codesign --force --sign - --identifier $(BUNDLE_ID) $@

notes-inspect: notes-inspect.m
	$(CC) $(CFLAGS) $< -o $@

generate: generate-notes-cli.py
	python3 generate-notes-cli.py > notekit-generated.m
	$(MAKE) notekit

install-hooks:
	git config core.hooksPath .githooks

clean:
	rm -f notekit notes-inspect

.PHONY: all clean generate install-hooks
