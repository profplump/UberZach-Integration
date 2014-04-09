STD_FLAGS=-fobjc-arc
FRAMES=-framework AppKit

default: speak cli
.PHONY: clean

clean:
	rm -f *.o speak cli

cli.o: cli.m
	gcc -c cli.m

cli: cli.o
	gcc $(FRAMES) -o cli cli.o

speak.o: speak.m
	gcc $(STD_FLAGS) -c speak.m

speak: speak.o
	gcc $(FRAMES) $(STD_FLAGS) -o speak speak.m
