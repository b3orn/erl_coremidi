#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMIDI/CoreMIDI.h>


#define ECM_OK 0
#define ECM_ERROR 1

typedef size_t ecm_error_t;


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


ecm_error_t ecm_find_device(CFStringRef devName, MIDIDeviceRef *destination) {
    OSStatus status;
    MIDIDeviceRef device;
    CFComparisonResult result;
    CFStringRef name;
    ItemCount count, i;

    count = MIDIGetNumberOfDevices();

    for (i = 0; i < count; ++i) {
        device = MIDIGetDevice(i);

        status = MIDIObjectGetStringProperty(device, kMIDIPropertyName, &name);

        if (status == noErr) {
            result = CFStringCompare(name, devName, 0);
            
            if (result == kCFCompareEqualTo) {
                *destination = device;

                return ECM_OK;
            }
        }
    }

    return ECM_ERROR;
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

    if (argc < 3) {
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

    if (ecm_find_device(deviceName, &device) != ECM_OK) {
        goto fail;
    }

    CFRelease(deviceName);

    entity = MIDIDeviceGetEntity(device, atoi(argv[2]));
    source = MIDIEntityGetSource(entity, 0);
    destination = MIDIEntityGetDestination(entity, 0);

    status = MIDIInputPortCreate(
        client,
        CFSTR("ecm-device"),
        ecm_receive,
        NULL,
        &sourcePort);

    if (status != noErr) {
        goto fail;
    }

    status = MIDIOutputPortCreate(
        client,
        CFSTR("ecm-device"),
        &destinationPort);

    if (status != noErr) {
        MIDIPortDispose(sourcePort);
        goto fail;
    }

    MIDIPortConnectSource(sourcePort, source, NULL);

    while ((len = read_cmd(cmd_buf)) > 0) {
        char buffer[100];
        char cmd[len];
        MIDIPacketList *packets = (MIDIPacketList*)buffer;
        MIDIPacket *packet;

        memcpy(cmd, cmd_buf, len);

        packet = MIDIPacketListInit(packets);

        MIDIPacketListAdd(packets, 100, packet, 0, len, cmd);

        MIDISend(destinationPort, destination, packets);
    }

    MIDIPortDisconnectSource(sourcePort, source);
    MIDIPortDispose(sourcePort);
    MIDIPortDispose(destinationPort);

fail:
    MIDIClientDispose(client);

    return EXIT_SUCCESS;
}
