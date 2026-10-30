// Shared controller/DSU motion fusion in Switch axes. Rates enter in degrees/s.
#pragma once
#include "dm_input.h"
#include <math.h>
#include <string.h>
#define RAD_PER_DEG (3.14159265358979323846 / 180.0)

typedef struct {
    uint64_t timestamp;
    uint32_t sequence, server;
    double accel[3], gyro[3]; // g and degrees/s, in Switch axes
} motion_packet;

typedef struct {
    double q[4], raw_q[4], bias[3], sum[3], sum2[3], gravity_sum[3]; // w,x,y,z
    uint64_t timestamp, calibration_start;
    uint32_t sequence, server;
    unsigned count;
    int ready, has_packet;
    dm_sixaxis_state state;
    float raw_direction[3][3];
} motion_filter;

static double length3(const double v[3]) { return sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]); }
static void normalize_q(double q[4]) {
    double n = sqrt(q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3]);
    for (int i = 0; i < 4; i++) q[i] /= n;
}
static void gravity_pose(double q[4], const double a[3]) {
    double n = length3(a);
    // Shortest rotation taking measured gravity to world down (0,0,-1).
    q[0] = 1 - a[2]/n; q[1] = -a[1]/n; q[2] = a[0]/n; q[3] = 0;
    if (q[0] < 1e-8) { q[0] = 0; q[1] = 1; q[2] = q[3] = 0; }
    normalize_q(q);
}
static void direction(const double q[4], float d[3][3]) {
    double w=q[0], x=q[1], y=q[2], z=q[3];
    // Basis vectors in world space (transpose of the column-vector rotation).
    d[0][0]=1-2*(y*y+z*z); d[0][1]=2*(x*y+w*z); d[0][2]=2*(x*z-w*y);
    d[1][0]=2*(x*y-w*z); d[1][1]=1-2*(x*x+z*z); d[1][2]=2*(y*z+w*x);
    d[2][0]=2*(x*z+w*y); d[2][1]=2*(y*z-w*x); d[2][2]=1-2*(x*x+y*y);
}
static void integrate(double q[4], const double rate[3], double dt) {
    double speed = length3(rate), half = speed * dt * 0.5;
    double k = speed > 1e-10 ? sin(half)/speed : dt*0.5;
    double w=cos(half), x=rate[0]*k, y=rate[1]*k, z=rate[2]*k;
    double a=q[0], b=q[1], c=q[2], d=q[3];
    q[0]=a*w-b*x-c*y-d*z; q[1]=a*x+b*w+c*z-d*y;
    q[2]=a*y-b*z+c*w+d*x; q[3]=a*z+b*y-c*x+d*w;
    normalize_q(q);
}
static void reset_filter(motion_filter *f) { memset(f, 0, sizeof *f); f->q[0] = f->raw_q[0] = 1; }
static void reset_capture(motion_filter *f) {
    f->count = 0; f->calibration_start = 0;
    memset(f->sum, 0, sizeof f->sum); memset(f->sum2, 0, sizeof f->sum2);
    memset(f->gravity_sum, 0, sizeof f->gravity_sum);
}
static int filter_packet(motion_filter *f, const motion_packet *p) {
    // Do not integrate repeated/reordered sensor samples or a repeated timestamp.
    if (f->has_packet && p->server == f->server &&
        ((int32_t)(p->sequence - f->sequence) <= 0 || p->timestamp <= f->timestamp)) return 0;
    if (f->has_packet && p->server != f->server) reset_filter(f);
    uint64_t dt_us = f->has_packet ? p->timestamp - f->timestamp : 0;
    f->timestamp=p->timestamp; f->sequence=p->sequence; f->server=p->server; f->has_packet=1;
    double norm = length3(p->accel);
    if (!f->ready) {
        // Bias is learned only during explicit connection/calibration, never
        // during play: slow steady rotation must not be mistaken for drift.
        if (norm < 0.9 || norm > 1.1 || length3(p->gyro) > 5 || dt_us > 250000) reset_capture(f);
        else {
            if (!f->count) f->calibration_start = p->timestamp;
            f->count++;
            for (int i=0;i<3;i++) {
                f->sum[i]+=p->gyro[i]; f->sum2[i]+=p->gyro[i]*p->gyro[i]; f->gravity_sum[i]+=p->accel[i];
            }
            if (f->count >= 20 && p->timestamp-f->calibration_start >= 1000000) {
                int stable=1;
                for (int i=0;i<3;i++) {
                    f->bias[i]=f->sum[i]/f->count;
                    if (f->sum2[i]/f->count-f->bias[i]*f->bias[i] > 0.25) stable=0;
                }
                if (!stable) reset_capture(f);
                else {
                    gravity_pose(f->q, f->gravity_sum); memcpy(f->raw_q, f->q, sizeof f->q);
                    memset(&f->state, 0, sizeof f->state); f->ready=1; dt_us=0;
                }
            }
        }
        if (!f->ready) return 1;
    }
    // A missing interval cannot be reconstructed from its last rate. Resume
    // with fresh data instead of extrapolating through a stalled connection.
    double dt = dt_us <= 250000 ? dt_us / 1e6 : 0;
    double rate[3], corrected[3];
    for (int i=0;i<3;i++) rate[i]=corrected[i]=(p->gyro[i]-f->bias[i])*RAD_PER_DEG;
    if (norm > 0.9 && norm < 1.1) {
        float basis[3][3]; direction(f->q, basis);
        double pred[3]={-basis[0][2],-basis[1][2],-basis[2][2]};
        double a[3]={p->accel[0]/norm,p->accel[1]/norm,p->accel[2]/norm};
        // Mahony proportional gravity correction; no integral bias adaptation.
        corrected[0]+=a[1]*pred[2]-a[2]*pred[1];
        corrected[1]+=a[2]*pred[0]-a[0]*pred[2];
        corrected[2]+=a[0]*pred[1]-a[1]*pred[0];
    }
    integrate(f->q, corrected, dt); integrate(f->raw_q, rate, dt);
    for (int i=0;i<3;i++) {
        f->state.acceleration[i]=p->accel[i];
        f->state.angular_velocity[i]=(p->gyro[i]-f->bias[i])/360.0;
        f->state.angle[i]+=f->state.angular_velocity[i]*dt;
    }
    f->state.delta_time=(dt_us<=250000?dt_us:0)*1000; f->state.sampling++;
    f->state.attributes=1; direction(f->q,f->state.direction); direction(f->raw_q,f->raw_direction);
    return 1;
}
