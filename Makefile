CC = clang
CFLAGS = -framework Foundation -framework CoreData -lobjc -O2

all: notekit

notekit: notekit.m
	$(CC) $(CFLAGS) $< -o $@

notes-inspect: notes-inspect.m
	$(CC) $(CFLAGS) $< -o $@

generate: generate-notes-cli.py
	python3 generate-notes-cli.py > notekit.m.tmp && mv notekit.m.tmp notekit.m
	$(MAKE) notekit

install-hooks:
	git config core.hooksPath .githooks

clean:
	rm -f notekit notes-inspect

.PHONY: all clean generate install-hooks
