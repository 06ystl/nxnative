// Known physical rotations + a real UDP server exercise the DSU receiver and
// values returned by nn::hid, including coexistence with Xbox/keyboard input.
#include "../motion_dsu_mac.c"
#include "../hle_hid.c"
#include <signal.h>
#include <sys/wait.h>

static int checks, fails, mode=1;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr,"FAIL: %s (line %d)\n",msg,__LINE__); } } while (0)
#define NEAR(a,b,e) (fabs((double)(a)-(double)(b))<(e))
int dm_opmode(void) { return mode; }
uint64_t dm_guest_frame(void) { return 0; }
void hle_bind_system_event(void *event, int autoclear) { (void)event; (void)autoclear; }
void hle_signal_system_event(void *event) { (void)event; }

static void from_hex(const char *hex, unsigned char *p) {
    for (unsigned i=0;i<strlen(hex)/2;i++) { unsigned value; sscanf(hex+2*i,"%2x",&value); p[i]=value; }
}
static void protocol_test(void) {
    // Fixtures generated independently with Python struct + zlib.crc32.
    unsigned char expected[28], req[28], data[100];
    from_hex("44535543e9030c00a637cebd78563412020010000100000000000000",expected);
    subscription(req,0x12345678); CHECK(!memcmp(req,expected,28),"DSUC subscription matches independent protocol fixture");
    from_hex("44535553e90354004d9f4995785634120200100000020202000000000000000107000000000000000000000000000000000000000000000000000000000000000000000087d612000000000000000000000080bf000000000000b4420000344300008743",data);
    motion_packet p;
    CHECK(decode_packet(data,100,&p),"accept known valid DSUS motion packet");
    CHECK(p.timestamp==1234567 && p.sequence==7,"sensor clock and packet sequence decode exactly");
    CHECK(p.accel[0]==0 && p.accel[1]==0 && p.accel[2]==-1,"screen-up gravity maps to negative Switch Z");
    CHECK(p.gyro[0]==90 && p.gyro[1]==270 && p.gyro[2]==-180,"DSU pitch/roll/yaw map to Switch X/Y/Z");
    CHECK(!decode_packet(data,99,&p),"reject truncated packet");
    data[40]^=1; CHECK(!decode_packet(data,100,&p),"reject bad CRC"); data[40]^=1;
    data[20]=1; put32(data+8,packet_crc(data,100)); CHECK(!decode_packet(data,100,&p),"do not merge a different DSU slot");
    data[20]=0; put32(data+76,0x7fc00000); put32(data+8,packet_crc(data,100));
    CHECK(!decode_packet(data,100,&p),"reject NaN before it can poison fusion");
}
static void socket_error_test(void) {
    // Darwin may signal SIGPIPE on a UDP send as well as on stream sockets.
    // Exercise a real EPIPE with the default signal disposition in a child:
    // a missing per-socket protection must fail this test, not kill the runner.
    int server=socket(AF_INET,SOCK_DGRAM,0);
    struct sockaddr_in address={.sin_len=sizeof address,.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    CHECK(server>=0 && !bind(server,(void *)&address,sizeof address),"bind socket error fixture");
    if(server<0) return;
    socklen_t size=sizeof address;getsockname(server,(void *)&address,&size);
    pid_t child=fork();
    if(child==0) {
        signal(SIGPIPE,SIG_DFL);
        char error[192];int fd=open_socket("127.0.0.1",ntohs(address.sin_port),error,sizeof error);
        if(fd<0 || shutdown(fd,SHUT_WR)) _exit(2);
        ssize_t n=send(fd,"test",4,0);int err=errno;close(fd);
        _exit(n<0 && err==EPIPE?0:3);
    }
    int status=0;
    CHECK(child>0 && waitpid(child,&status,0)==child,"socket fault child completes");
    if(WIFSIGNALED(status))fprintf(stderr,"socket child signal: %d\n",WTERMSIG(status));
    CHECK(WIFEXITED(status) && WEXITSTATUS(status)==0,"UDP EPIPE is returned as an error without terminating the app");
    close(server);
}
static motion_packet still_packet(void) { return (motion_packet){.server=1,.timestamp=1000000,.sequence=1,.accel={0,0,-1}}; }
static void step(motion_filter *f, motion_packet *p, unsigned us) {
    p->sequence++; p->timestamp+=us; CHECK(filter_packet(f,p),"fresh sensor sample accepted");
}
static void calibrate(motion_filter *f, motion_packet *p) {
    reset_filter(f);
    for (int i=0;i<110;i++) step(f,p,10000);
    CHECK(f->ready,"one second at rest completes calibration");
}
static void rotation_test(void) {
    for (int axis=0;axis<3;axis++) {
        motion_filter f; motion_packet p=still_packet(); calibrate(&f,&p);
        for (int i=1;i<=100;i++) {
            double angle=i*(3.14159265358979323846/2)/100;
            p.gyro[axis]=90;
            if (axis==0) { p.accel[1]=-sin(angle); p.accel[2]=-cos(angle); }
            if (axis==1) { p.accel[0]=sin(angle); p.accel[2]=-cos(angle); }
            step(&f,&p,10000);
        }
        CHECK(NEAR(f.state.angular_velocity[axis],0.25,1e-6),"90 degrees/s is one quarter revolution/s");
        CHECK(NEAR(f.state.angle[axis],0.25,1e-5),"one second rotates one quarter turn");
        CHECK(f.state.delta_time==10000000,"10 ms sensor period reported in nanoseconds");
        int row=(axis+1)%3, col=(axis+2)%3;
        CHECK(NEAR(f.state.direction[row][col],1,0.02),"positive quarter turn produces the expected signed basis");
        CHECK(NEAR(f.state.direction[col][row],-1,0.02),"direction matrix is transposed into the Switch basis convention");
        p.gyro[axis]=0;
        for (int i=0;i<500;i++) step(&f,&p,10000);
        CHECK(NEAR(f.state.direction[row][col],1,0.02),"held 90-degree tilt stays tilted at rest");
        CHECK(NEAR(f.state.angle[axis],0.25,1e-5),"holding a tilt does not keep adding rotation");
        double old=f.state.angle[axis];
        CHECK(!filter_packet(&f,&p),"duplicate sensor packet is ignored");
        p.sequence--; p.timestamp-=10000;
        CHECK(!filter_packet(&f,&p),"out-of-order packet is ignored");
        CHECK(f.state.angle[axis]==old,"duplicates and reordering cannot rotate the game");
    }
    motion_filter f; motion_packet p=still_packet(); p.gyro[0]=0.5; calibrate(&f,&p);
    p.gyro[0]=0.5; for (int i=0;i<100;i++) step(&f,&p,10000);
    CHECK(NEAR(f.state.angle[0],0,1e-7),"explicit rest calibration removes constant gyro bias");
    p.gyro[0]=1.5; for (int i=0;i<500;i++) step(&f,&p,10000);
    CHECK(NEAR(f.state.angle[0],5.0/360,1e-6),"slow steady motion is never learned away as drift");
    p.gyro[0]=90; double before=f.state.angle[0]; step(&f,&p,400000);
    CHECK(f.state.angle[0]==before,"missing network interval is not extrapolated from a stale rate");
    for (int i=0;i<3;i++) for (int j=0;j<3;j++) {
        double dot=0; for(int k=0;k<3;k++)dot+=f.state.direction[i][k]*f.state.direction[j][k];
        CHECK(NEAR(dot,i==j?1:0,1e-6),"orientation basis remains orthonormal");
    }
    reset_filter(&f); p=still_packet(); p.accel[2]=0;
    for (int i=0;i<110;i++) step(&f,&p,10000);
    CHECK(!f.ready,"disabled accelerometer cannot produce a calibrated pose");
}

typedef struct { int fd; _Atomic int stop, stream, turn, requests; } fake_server;
static void *serve(void *arg) {
    fake_server *s=arg; struct sockaddr_storage peer; socklen_t peer_size=0;
    uint32_t seq=0; uint64_t requested=0, next=0;
    while (!atomic_load(&s->stop)) {
        struct pollfd pf={.fd=s->fd,.events=POLLIN};
        if(poll(&pf,1,5)>0) {
            unsigned char req[256]; peer_size=sizeof peer;
            ssize_t n=recvfrom(s->fd,req,sizeof req,0,(void *)&peer,&peer_size);
            if(n==28 && !memcmp(req,"DSUC",4) && le32(req+8)==packet_crc(req,28) && req[20]==1 && !req[21]) {
                requested=motion_now(); atomic_fetch_add(&s->requests,1);
            }
        }
        uint64_t now=motion_now();
        if (requested && now-requested<3000000000ull && now>=next && atomic_load(&s->stream)) {
            unsigned char p[100]={0}; memcpy(p,"DSUS",4); put16(p+4,1001);put16(p+6,84);put32(p+12,99);
            put32(p+16,0x100002);p[21]=2;p[22]=2;p[23]=2;p[31]=1;put32(p+32,++seq);
            uint64_t us=now/1000;put32(p+68,us);put32(p+72,us>>32);
            float values[6]={0,-1,0,0,atomic_load(&s->turn)?-90:0,0}; // yaw +Z in Switch axes
            for (int i=0;i<6;i++) { uint32_t bits;memcpy(&bits,&values[i],4);put32(p+76+i*4,bits); }
            put32(p+8,packet_crc(p,100));sendto(s->fd,p,sizeof p,0,(void *)&peer,peer_size);
            next=now+10000000;
        }
    }
    return NULL;
}
static dm_dsu_client *client;
static int source(dm_sixaxis_state *s,int fusion) { return dm_dsu_read(client,s,fusion); }
static int wait_phase(dm_dsu_phase phase,int milliseconds) {
    for (int i=0;i<milliseconds/10;i++) { if(dm_dsu_get_status(client).phase==phase)return 1;usleep(10000); }
    return 0;
}
static void network_hid_test(void) {
    fake_server server={.fd=socket(AF_INET,SOCK_DGRAM,0),.stream=1};
    struct sockaddr_in address={.sin_len=sizeof address,.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    CHECK(server.fd>=0 && !bind(server.fd,(void *)&address,sizeof address),"bind loopback MotionSource simulator");
    if(fails) { if(server.fd>=0)close(server.fd); return; }
    socklen_t size=sizeof address;getsockname(server.fd,(void *)&address,&size);
    pthread_t worker;pthread_create(&worker,NULL,serve,&server);
    client=dm_dsu_create();CHECK(client!=NULL,"start asynchronous DSU client");
    dm_motion_read=source;dm_dsu_configure(client,"127.0.0.1",ntohs(address.sin_port));
    CHECK(wait_phase(DM_DSU_READY,4000),"real UDP samples complete initial calibration");
    uint32_t id=0,handle=0;
    CHECK(h_hid_SixHandles(&handle,1,&id,STYLE_FULLKEY)==1 && handle==0x020003,"full-key handle uses Horizon fields");
    dm_sixaxis_state state[2];memset(state,0x5a,sizeof state);
    CHECK(h_hid_SixStates(state,1,&handle)==0,"sensor must be started before use");
    h_hid_SixStart(&handle);
    CHECK(h_hid_SixStates(state,2,&handle)==1 && state[0].attributes==1,"real GetSixAxisSensorStates returns connected motion");
    CHECK(((unsigned char *)&state[1])[0]==0x5a,"current-only provider leaves additional output entries untouched");
    CHECK(h_hid_SixRest(&handle),"calibrated flat phone reports at rest");
    atomic_store(&server.turn,1);usleep(100000);h_hid_SixState(state,&handle);
    CHECK(NEAR(state[0].angular_velocity[2],0.25,1e-4),"server yaw reaches actual guest state in turns/s");
    CHECK(!h_hid_SixRest(&handle),"rotating phone reports motion");
    uint64_t sampling=state[0].sampling;
    dm_input_set(DM_BTN_Y,32767,0,0,0);dm_pad_set(DM_BTN_A,0,0,-32767,0);
    NpadState pad;h_hid_StateFullKey(&pad,&id);
    CHECK((pad.buttons&0xffff)==(DM_BTN_A|DM_BTN_Y) && pad.lx==32767 && pad.rx==-32767,"phone motion preserves Xbox and keyboard inputs");
    CHECK(h_hid_SixFusionQ(&handle),"fusion defaults on");h_hid_SixFusionOn(&handle,0);
    CHECK(!h_hid_SixFusionQ(&handle),"fusion switch is remembered");h_hid_SixFusionOn(&handle,1);
    dm_dsu_set_active(client,0);h_hid_SixState(state,&handle);
    CHECK(!state[0].attributes && !state[0].angular_velocity[2],"focus loss disconnects motion and clears stale velocity");
    dm_dsu_set_active(client,1);CHECK(h_hid_SixStates(state,1,&handle)==1,"focus return restores fresh sensor state");
    h_hid_SixStop(&handle);CHECK(!h_hid_SixStates(state,1,&handle),"stopped sensor reports no samples");h_hid_SixStart(&handle);
    mode=0;id=0x20;uint32_t handheld;
    CHECK(h_hid_SixHandles(&handheld,1,&id,STYLE_HANDHELD)==1 && handheld==0x020804,"handheld handle has player index eight");
    h_hid_SixStart(&handheld);CHECK(h_hid_SixStates(state,1,&handheld)==1,"handheld play receives the same phone motion");
    CHECK(!h_hid_SixStates(state,1,&handle),"wrong-player/style handle cannot read current sensor");mode=1;
    // Let the three-second MotionSource client lease expire unless renewed.
    usleep(2200000);
    CHECK(atomic_load(&server.requests)>=3 && h_hid_SixStates(state,1,&handle)==1,"periodic subscription keeps MotionSource streaming");
    atomic_store(&server.stream,0);usleep(650000);
    CHECK(!h_hid_SixStates(state,1,&handle) && !state[0].attributes,"sensor silence expires the state");
    atomic_store(&server.turn,0);atomic_store(&server.stream,1);
    CHECK(wait_phase(DM_DSU_READY,4000),"reconnection automatically recalibrates from fresh data");
    h_hid_SixState(state,&handle);CHECK(state[0].sampling>sampling,"sampling number stays monotonic across reconnect/calibration");
    dm_dsu_calibrate(client);CHECK(!h_hid_SixStates(state,1,&handle),"explicit calibration withholds incomplete sensor data");
    CHECK(wait_phase(DM_DSU_READY,4000),"explicit recalibration completes");
    dm_dsu_configure(client,"",0);CHECK(!h_hid_SixStates(state,1,&handle),"disconnect stops motion immediately");
    dm_dsu_destroy(client);dm_motion_read=NULL;
    atomic_store(&server.stop,1);pthread_join(worker,NULL);close(server.fd);
}
int main(void) {
    protocol_test();socket_error_test();rotation_test();network_hid_test();
    printf("motion: %d checks, %d failures\n",checks,fails);return fails!=0;
}
