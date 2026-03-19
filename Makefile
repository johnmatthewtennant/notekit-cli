CC = clang
CFLAGS = -framework Foundation -framework CoreData -lobjc -O2

all: notekit

notekit: notekit.m notekit-generated.m notekit-handwritten.m notekit-tests.m
	$(CC) $(CFLAGS) $< -o $@

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
