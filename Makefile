CC = clang
CFLAGS = -framework Foundation -framework CoreData -lobjc -O2

all: notekit

notekit: notekit.m
	$(CC) $(CFLAGS) $< -o $@

notes-inspect: notes-inspect.m
	$(CC) $(CFLAGS) $< -o $@

generate: generate-notes-cli.py
	python3 generate-notes-cli.py > notekit.m
	$(MAKE) notekit

clean:
	rm -f notekit notes-inspect

.PHONY: all clean generate
