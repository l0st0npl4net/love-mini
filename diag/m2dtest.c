// The Mini's screen through libmini2d alone (no LOVE, no Lua): colour bars that move
// for about 3 seconds, then a clean exit. Each step is said on stdout, so a crash
// shows where it happened. Part of love-mini's diag.sh.
#include <stdint.h>
#include <stdio.h>

typedef struct m2d_surf m2d_surf;
void m2d_screen_size(int *w, int *h);
int m2d_init(int w, int h);
m2d_surf *m2d_backbuffer(void);
void m2d_clear(m2d_surf *d, uint32_t argb, int use_clip);
void m2d_fill(m2d_surf *d, int x, int y, int w, int h, uint32_t argb, int blend);
void m2d_present(void);
int m2d_poll_key(int *code, int *value);
void m2d_quit(void);

int main(void)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    int w = 0, h = 0;
    printf("m2dtest: screen size\n");
    m2d_screen_size(&w, &h);
    printf("m2dtest: %dx%d, init\n", w, h);
    int rc = m2d_init(w, h);
    printf("m2dtest: init: %d\n", rc);
    if (rc != 0) return 1;
    static const uint32_t bars[] = { 0xffff0000, 0xff00ff00, 0xff0000ff, 0xffffffff };
    int keys = 0, code, value;
    for (int f = 0; f < 180; f++) {
        m2d_surf *b = m2d_backbuffer();
        m2d_clear(b, 0xff000000, 0);
        for (int i = 0; i < 4; i++)
            m2d_fill(b, (f * 3 + i * w / 4) % w, h / 4, w / 8, h / 2, bars[i], 0);
        // the top left corner: white, so the picture's way up can be told
        m2d_fill(b, 0, 0, 40, 40, 0xffffffff, 0);
        m2d_present();
        if (f == 0) printf("m2dtest: first frame shown\n");
        while (m2d_poll_key(&code, &value)) keys++;
    }
    printf("m2dtest: 180 frames, %d key events; quit\n", keys);
    m2d_quit();
    printf("m2dtest: done\n");
    return 0;
}
