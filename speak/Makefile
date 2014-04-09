STD_FLAGS=-fobjc-arc
FRAMES=-framework AppKit

default: speak
.PHONY: clean

clean:
	rm -f *.o speak say

say.o: say.m
	gcc -c say.m

say: say.o
	gcc $(FRAMES) -o say say.o

speak.o: speak.m
	gcc $(STD_FLAGS) -c speak.m

speak: speak.o
	gcc $(FRAMES) $(STD_FLAGS) -o speak speak.m
