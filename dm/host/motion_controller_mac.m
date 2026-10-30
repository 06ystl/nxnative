// GCMotion uses the same physical axes as the portrait phone source: x right,
// y toward the top edge, z out of the face. Feed the shared fusion in degrees/s.
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#include <pthread.h>
#include <stdio.h>
#include <time.h>
#include "motion_controller_mac.h"
#include "motion_filter_mac.h"

static GCController *g_motion_controller;
static GCMotion *g_controller_sensor;
static int g_controller_motion_enabled, g_controller_motion_active, g_controller_motion_running;
static pthread_mutex_t g_controller_motion_lock = PTHREAD_MUTEX_INITIALIZER;
static motion_filter g_controller_filter;
static uint64_t g_controller_received, g_controller_sampling;
static uint32_t g_controller_sequence;

static void controller_motion_clear(void) { // snapshot lock held
    reset_filter(&g_controller_filter); g_controller_received = 0;
}
static void controller_motion_sample(GCMotion *motion) { // controller's main handler queue
    if (!g_controller_motion_running || motion != g_controller_sensor) return;
    GCAcceleration a = motion.acceleration;
    if (motion.hasGravityAndUserAcceleration) {
        GCAcceleration gravity = motion.gravity, user = motion.userAcceleration;
        a = (GCAcceleration){gravity.x + user.x, gravity.y + user.y, gravity.z + user.z};
    }
    GCRotationRate r = motion.rotationRate;
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    motion_packet packet = {.timestamp=now/1000, .sequence=++g_controller_sequence, .server=1,
        .accel={a.x,a.y,a.z}, .gyro={r.x/RAD_PER_DEG,r.y/RAD_PER_DEG,r.z/RAD_PER_DEG}};
    for (int i=0;i<3;i++) if (!isfinite(packet.accel[i]) || !isfinite(packet.gyro[i])) return;
    pthread_mutex_lock(&g_controller_motion_lock);
    if (g_controller_received && now-g_controller_received > 500000000ull) controller_motion_clear();
    if (filter_packet(&g_controller_filter,&packet)) {
        g_controller_received = now;
        if (g_controller_filter.ready) g_controller_filter.state.sampling = ++g_controller_sampling;
    }
    pthread_mutex_unlock(&g_controller_motion_lock);
}
static void controller_motion_refresh(void) { // main queue
    int running = g_controller_motion_enabled && g_controller_motion_active && g_controller_sensor.hasRotationRate;
    if (!running) {
        if (g_controller_motion_running) {
            g_controller_sensor.valueChangedHandler = nil;
            if (g_controller_sensor.sensorsRequireManualActivation) g_controller_sensor.sensorsActive = NO;
        }
        pthread_mutex_lock(&g_controller_motion_lock);
        g_controller_motion_running = 0; controller_motion_clear();
        pthread_mutex_unlock(&g_controller_motion_lock);
        return;
    }
    if (!g_controller_motion_running) {
        pthread_mutex_lock(&g_controller_motion_lock);
        controller_motion_clear(); g_controller_motion_running = 1;
        pthread_mutex_unlock(&g_controller_motion_lock);
        if (g_controller_sensor.sensorsRequireManualActivation) g_controller_sensor.sensorsActive = YES;
    }
    // Eligible focus/display refreshes also repair a lost handler on the same pad.
    g_controller_sensor.valueChangedHandler = ^(GCMotion *changed) { controller_motion_sample(changed); };
}
void dm_controller_motion_attach(GCController *controller) {
    GCMotion *sensor = controller.motion;
    if (controller != g_motion_controller || sensor != g_controller_sensor) {
        if (g_controller_motion_running) {
            g_controller_sensor.valueChangedHandler = nil;
            if (g_controller_sensor.sensorsRequireManualActivation) g_controller_sensor.sensorsActive = NO;
        }
        pthread_mutex_lock(&g_controller_motion_lock);
        g_controller_motion_running = 0; controller_motion_clear();
        pthread_mutex_unlock(&g_controller_motion_lock);
        g_motion_controller = controller; g_controller_sensor = sensor;
        if (controller && g_controller_motion_enabled)
            fprintf(stderr,"[dm] Controller motion: %s; %s\n",controller.vendorName.UTF8String ?: "controller",
                    sensor.hasRotationRate ? "motion API exposed; checking sensor data" : "gyro unavailable on this connection");
    }
    controller_motion_refresh();
}
void dm_controller_motion_enable(int enabled) {
    g_controller_motion_enabled = !!enabled; controller_motion_refresh();
    if (enabled && g_motion_controller)
        fprintf(stderr,"[dm] Controller motion: %s\n",g_controller_sensor.hasRotationRate ? "motion API selected; checking sensor data" : "gyro unavailable on this connection");
}
void dm_controller_motion_set_active(int active) {
    g_controller_motion_active = !!active; controller_motion_refresh();
}
void dm_controller_motion_calibrate(void) {
    pthread_mutex_lock(&g_controller_motion_lock); controller_motion_clear(); pthread_mutex_unlock(&g_controller_motion_lock);
}
dm_controller_motion_status dm_controller_motion_get_status(void) {
    pthread_mutex_lock(&g_controller_motion_lock);
    const char *message = "Controller gyro unavailable";
    if (g_controller_sensor.hasRotationRate) {
        if (!g_controller_motion_running) message = "Controller motion paused";
        else if (!g_controller_received || clock_gettime_nsec_np(CLOCK_MONOTONIC)-g_controller_received>500000000ull)
            message = "Waiting for controller motion";
        else if (!g_controller_filter.ready && !g_controller_filter.count)
            message = "Waiting for usable controller motion data";
        else message = g_controller_filter.ready ? "Controller motion connected" : "Calibrating: hold the controller still for one second";
    }
    dm_controller_motion_status status = {message,g_controller_motion_running};
    pthread_mutex_unlock(&g_controller_motion_lock); return status;
}
int dm_controller_motion_read(dm_sixaxis_state *state, int fusion) {
    pthread_mutex_lock(&g_controller_motion_lock);
    int ok = g_controller_motion_running && g_controller_filter.ready && g_controller_received &&
             clock_gettime_nsec_np(CLOCK_MONOTONIC)-g_controller_received<=500000000ull;
    memset(state,0,sizeof *state);
    if (ok) {
        *state = g_controller_filter.state;
        if (!fusion) memcpy(state->direction,g_controller_filter.raw_direction,sizeof state->direction);
    }
    pthread_mutex_unlock(&g_controller_motion_lock); return ok;
}
