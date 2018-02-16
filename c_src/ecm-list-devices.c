#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMIDI/CoreMIDI.h>


int main(int argc, char **argv) {
    ItemCount i, j;
    ItemCount device_count = MIDIGetNumberOfDevices();

    printf("[");

    for (i = 0; i < device_count; ++i) {
        MIDIDeviceRef device = MIDIGetDevice(i);
        ItemCount entity_count = MIDIDeviceGetNumberOfEntities(device);
        SInt32 offline = 0;
        CFStringRef name;

        MIDIObjectGetStringProperty(device, kMIDIPropertyName, &name);
        MIDIObjectGetIntegerProperty(device, kMIDIPropertyOffline, &offline);

        /* CFStringGetLength returns length in utf-16 code pairs */
        CFIndex length = CFStringGetLength(name) * 2;
        char buffer[length];

        CFStringGetCString(name, buffer, length, kCFStringEncodingUTF8);

        printf("{\"%s\", %s, %d, [",
            buffer,
            offline ? "offline" : "online",
            entity_count);

        for (j = 0; j < entity_count; ++j) {
            MIDIEntityRef entity = MIDIDeviceGetEntity(device, j);
            ItemCount source_count = MIDIEntityGetNumberOfSources(entity);
            ItemCount dest_count = MIDIEntityGetNumberOfDestinations(entity);

            printf("{%d, %d}", source_count, dest_count);

            if (j + 1 < entity_count) {
                printf(", ");
            }
        }

        printf("]}");

        if (i + 1 < device_count) {
            printf(",");
        }
    }

    printf("].\n");

    return EXIT_SUCCESS;
}
