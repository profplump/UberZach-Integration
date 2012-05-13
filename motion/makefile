default: USBMicroX

USBMicroX: USBMicroX.o main.o
	gcc -framework CoreFoundation -framework IOKit -o USBMicroX USBMicroX.o main.o

main.o: main.c
	gcc -c main.c

USBMicroX.o: USBMicroX.c USBMicroX.h
	gcc -c USBMicroX.c

clean:
	rm -f main.o USBMicroX.o USBMicroX
