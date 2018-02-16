#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMIDI/CoreMIDI.h>


int read_exact(char *buf, int len) {
    int i, got=0;

    do {
        if ((i = read(0, buf+got, len-got)) <= 0) {
            return i;
        }

        got += i;
    } while (got<len);

  return len;
}


int write_exact(char *buf, int len) {
    int i, wrote = 0;

    do {
        if ((i = write(1, buf+wrote, len-wrote)) <= 0) {
            return i;
        }

        wrote += i;
    } while (wrote<len);

  return len;
}


int read_cmd(char *buf) {
    int len;

    if (read_exact(buf, 2) != 2) {
        return -1;
    }

    len = (buf[0] << 8) | buf[1];

    return read_exact(buf, len);
}


int write_cmd(char *buf, int len) {
    char li;

    li = (len >> 8) & 0xff;
    write_exact(&li, 1);

    li = len & 0xff;
    write_exact(&li, 1);

    return write_exact(buf, len);
}


void ecm_receive(const MIDIPacketList *packets, void *a, void *b) {
    unsigned int i;
    MIDIPacket *packet;

    packet = &(packets->packet[0]);

    for (i = 0; i < packets->numPackets; ++i) {
        write_cmd((char*)(packet->data), 3);

        packet = MIDIPacketNext(packet);
    }
}


int main(int argc, char **argv) {
    OSStatus status;
    MIDIClientRef client;
    MIDIDeviceRef device;
    MIDIEntityRef entity;
    MIDIEndpointRef source;
    MIDIEndpointRef destination;
    MIDIPortRef sourcePort;
    MIDIPortRef destinationPort;
    CFComparisonResult result;
    CFStringRef name;
    CFStringRef deviceName;
    int len;
    char cmd_buf[100];

    if (argc < 2) {
        return EXIT_FAILURE;
    }

    deviceName = CFStringCreateWithBytes(
        kCFAllocatorDefault,
        argv[1],
        strlen(argv[1]),
        kCFStringEncodingUTF8,
        false);

    status = MIDIClientCreate(CFSTR("ecm"), NULL, NULL, &client);

    if (status != noErr) {
        return EXIT_FAILURE;
    }

    MIDISourceCreate(client, deviceName, &destination);
    MIDIDestinationCreate(
        client,
        deviceName,
        ecm_receive,
        NULL,
        &source);

    while ((len = read_cmd(cmd_buf)) > 0) {
        char buffer[100];
        char cmd[len];
        MIDIPacketList *packets = (MIDIPacketList*)buffer;
        MIDIPacket *packet;

        memcpy(cmd, cmd_buf, len);

        packet = MIDIPacketListInit(packets);

        MIDIPacketListAdd(packets, 100, packet, 0, len, cmd);

        MIDIReceived(destination, packets);
    }

    MIDIEndpointDispose(source);
    MIDIEndpointDispose(destination);

fail:
    CFRelease(deviceName);

    MIDIClientDispose(client);

    return EXIT_SUCCESS;
}
