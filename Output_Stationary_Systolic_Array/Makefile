TARGET = matrix

CROSS_COMPILE = arm-linux-gnueabihf-
CC = $(CROSS_COMPILE)gcc

CFLAGS = -static -g -Wall
LDFLAGS = -g -Wall

build: $(TARGET)

$(TARGET): matrix.o
	$(CC) $(LDFLAGS) $^ -o $@

%.o : %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(TARGET) *.o