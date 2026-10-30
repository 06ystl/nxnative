# DualSense trigger feedback encoding

The ten-zone feedback packing and slope interpolation in
`dm/host/audio_haptics_usb_mac.c` are adapted from John "Nielk1" Klein's
MIT-licensed `ExtendInput.DataTools.DualSense.TriggerEffectGenerator.cs`
(copyright 2021–2022), available in the research sources of
[dualsense-controller-python](https://github.com/yesbotics/dualsense-controller-python/blob/main/research/ExtendInput.DataTools.DualSense.TriggerEffectGenerator.cs).
The local code converts normalized slopes to the USB feedback report and keeps
both trigger states in one report, with audio-haptics disabling bits clear.

The USB report field offsets and rumble/audio-mode flags were checked against
[SDL's PS5 HID driver](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_ps5.c).
The original license is retained in `LICENSE`.
