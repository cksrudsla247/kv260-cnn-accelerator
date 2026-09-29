# dma.v S_IDLE 레이스 버그 + AXI 경로 미검증 문제 수정

**날짜:** 2026-09-17
**증상:** `tb_top.v` 928개 골든 워드 중 918~922개 FAIL (928/928이어야 정상)

**결과 요약**

| 항목 | 상태 |
|------|------|
| `dma.v` S_IDLE 레이스 버그 | 수정, `tb_top.v` **928/928 PASS** |
| `axi4_master_dram.v` (AXI4 DDR 경로) | 이전엔 미검증 → `tb_axi4_dma.v` 신규 작성, **PASS** (뮤테이션 검증 완료) |
| `axi_lite_csr.v` `done` 1사이클 펄스 문제 | 발견 + 수정 (sticky latch), `tb_axi_lite_csr.v` 신규 작성, **PASS** (뮤테이션 검증 완료) |
| `top_kv260.v` (보드 실토폴로지 전체) | 이전엔 미검증 → `tb_top_kv260.v` 신규 작성. 테스트벤치의 `disable` 라벨 버그(RTL 아님) 발견·수정 후 **928/928 PASS** (§7 참고) |

---

## 1. 배경

`dma.v`는 원래 진짜 BRAM(고정 1사이클 read latency)을 가정하고 짜여 있었다. AXI4로 DDR에 접근하도록 바꾸면서 `dram_rdy` 핸드셰이크 기반의 새 FSM(`S_IDLE / S_RD_WAIT / S_WR_FETCH / S_WR_ISSUE / S_WR_WAIT`)으로 재작성했는데, 이 과정에서 `tb_top.v`가 918~922/928로 퇴행했다. `controller.v`의 CSR/주소 생성 로직, `dram` IP의 Output Register 설정, `core.v`의 `wb_row_nxt` 등은 모두 정상으로 확인됐고 원인이 되지 못했다.

## 2. 근본 원인

**`dma.v`의 `S_IDLE`이 자신의 `*_done` 펄스를 내보내는 바로 그 사이클에 `*_req`를 재검사**하는데, `controller.v`는 `*_done`을 본 **다음 사이클에야** `*_busy`(→`*_req`)를 내린다. 그 1사이클 틈에 dma가 "낡은" 요청 레벨을 새 요청으로 오인해서, **옛 버스트의 base/길이로 유령(phantom) 1워드 전송**을 시작해버린다. 이게 레이어 내부의 모든 그룹/청크 경계와 레이어 전환마다 발생해서, Conv1_1 출력부터 이미 오염되고 이후 5개 레이어로 전부 연쇄 전파됐다.

### 파형 증거 (Icarus Verilog로 재현, cyc는 100MHz 사이클)

Conv1_1이 0xB970에 쓰는 첫 그룹(128워드) 경계:

```
cyc=73779  dma_state=S_WR_WAIT  w=127  dram_en=1 dram_we=1 addr=b9ef   <- group0 마지막 워드, 정상
cyc=73781  dma_state=S_DONE_S
cyc=73782  dma_state=S_IDLE     s2mm_done=1  s2mm_busy=1  s2mm_req=1   <- *** controller가 아직 busy=1 ***
cyc=73783  dma_state=S_WR_FETCH w=0   wb_req=1                        <- 유령 요청 시작! (낡은 s2mm_req=1을 새 요청으로 오인)
cyc=73785  dma_state=S_WR_WAIT  dram_en=1 dram_we=1 addr=b970         <- group0 주소로 재기록 (옛 s2mm_base)
cyc=73786  s2mm_busy=1                                                <- controller가 이제서야 진짜 group1 요청을 세팅
cyc=73789  addr=bf91  (w=1)                                           <- w는 이미 1인데 group1 base(bf90)+1로 뒤섞임
```

### 코드 근거

`controller.v` — `*_busy`는 `*_done`을 본 **다음** 엣지에야 내려간다:

```verilog
// controller.v : 473-485
always @(posedge clk or posedge rst) begin
    if (rst) begin
        s2mm_busy <= 1'b0; ...
    end else if ((state_q == ST_OUT_REQ) && !s2mm_busy) begin
        s2mm_busy  <= 1'b1;
        s2mm_addr  <= wide_out ? out_base : (grp_base + ...);
        s2mm_words <= wide_out ? out_words : chunk_words;
    end else if (s2mm_done) begin
        s2mm_busy <= 1'b0;      // s2mm_done을 "본" 다음 엣지에야 반영
    end
end
```

`dma.v` (수정 전) — `S_IDLE`이 `*_done`을 내보내는 바로 그 사이클에 `*_req`를 재확인:

```verilog
// dma.v : 82-95 (수정 전)
case (state)
S_IDLE: begin
    w<=0;
    if (mm2s_req) begin
        ...
    end else if (s2mm_req) begin   // <- 낡은 req를 새 요청으로 오인
        wb_req <= 1'b1;
        wb_idx <= {LEN_W{1'b0}};
        state  <= S_WR_FETCH;
    end
end
```

### 왜 구버전 dma.v는 통과했는가

구버전(`Task_1_26_summer/.../dma.v`)의 `S_IDLE`에는 이 레이스를 막는 가드가 있었다:

```verilog
S_IDLE: begin
    b<=0; w<=0; idx<=0; ra_b<=0; ra_w<=0;
    if (mm2s_done || s2mm_done) begin
        // 아무것도 안 함 — 가드
    end else if (mm2s_req) begin
    ...
```

AXI 대응을 위해 FSM을 재작성하면서 **이 가드가 누락**됐다. 그게 928/928 → 918~922/928로 퇴행한 직접 원인이다.

## 3. 수정 내용

**파일:** `Task_1_26_summer.srcs/sources_1/new/dma.v`, `S_IDLE` 케이스

```verilog
S_IDLE: begin
    w<=0;
    // *_req is a level held by the controller until it sees our
    // *_done pulse; busy/req only drops the cycle AFTER that, so
    // on the very cycle we assert *_done and land back in S_IDLE,
    // the old request is technically still asserted. Without this
    // guard that stale level looks like a brand-new request and
    // we launch a 1-word phantom transfer at the OLD base/index
    // before the controller reprograms it for the real next
    // burst - corrupting one word at every mm2s/s2mm boundary.
    if (mm2s_done || s2mm_done) begin
        // just finished; wait one cycle for req to actually drop
    end else if (mm2s_req) begin
        dram_en   <= 1'b1;
        dram_we   <= 1'b0;
        dram_addr <= mm2s_base;
        state     <= S_RD_WAIT;
    end else if (s2mm_req) begin
        wb_req <= 1'b1;
        wb_idx <= {LEN_W{1'b0}};
        state  <= S_WR_FETCH;
    end
end
```

한 줄 요약: 구버전에 있던 "방금 끝냈으면 이번 사이클은 아무것도 시작하지 말고 한 박자 쉰다" 가드를 그대로 복원.

## 4. 검증 — `tb_top.v` (BRAM 직결 경로)

CSR 프로그램 인코딩(`dram.txt`의 csr_addr=9 등)과 ping-pong 주소 재사용(0xB970/0xD1F0)은 처음부터 `quant_cnn.py`가 의도한 정상 설계였고 버그가 아니었음도 함께 확인했다 (`out_base = ACT_A if (li % 2 == 0) else ACT_B`, `quant_cnn.py:449`).

Icarus Verilog로 실제 프로젝트 RTL 전체(dram IP, tester, controller, core, dma)를 그대로 컴파일해서 `tb_top.v`를 끝까지 돌린 결과:

```
$ awk '{if ($2 != $3) c++} END{print "mismatches:", c+0, "/", NR}' got.txt
mismatches: 0 / 928
```

**928/928 PASS.** 레이어별 사이클(참고, 이번 Icarus 실측):

| layer | 완료 시점(누적 cyc) |
|-------|---------------------|
| Conv1_1 | ~100,000 (dram_load 65,536 포함) |
| Conv1_2 | ~230,000 |
| Conv2_1 | ~315,000 |
| Conv2_2 | ~460,000 |
| Conv3   | ~550,000 |
| Affine  | ~560,000+ |

## 5. 새로 추가한 테스트 — `tb_axi4_dma.v` (AXI4 경로)

### 왜 필요한가

`tb_top.v`는 `dma.v`를 **tester.v의 진짜 BRAM(고정 1사이클 latency)에 직결**해서만 테스트한다. KV260 실기판에서 실제로 타는 경로는 `dma.v` → **`axi4_master_dram.v`(AXI4 master) → PS의 DDR HP 포트**이고, 이 AXI 경로는 `top_kv260.v` 안에서만 인스턴스화될 뿐 **지금까지 어떤 테스트벤치도 실행해본 적이 없었다.** `dma.v`를 애초에 "가변 레이턴시 핸드셰이크" 방식으로 다시 짠 이유가 바로 이 AXI 경로 때문이므로, 정작 제일 중요한 부분이 미검증 상태로 남아 있었다.

### 파일

**`Task_1_26_summer.srcs/sim_1/new/tb_axi4_dma.v`** (신규)

- `dma.v` + `axi4_master_dram.v`를 실제 컨트롤러 없이 최소 stub으로 직접 구동.
  - s2mm 경로: `wb_req/wb_idx`에 응답하는 `wb_data`를 1사이클 지연 동기 리드(core.v의 obuf와 동일한 타이밍 계약)로 제공.
  - mm2s 경로: `strm_vld/strm_data/strm_idx`를 캡처해서 로컬 메모리에 기록.
- **가변 레이턴시 AXI4 슬레이브 BFM**을 직접 구현 (PS DDR HP 포트를 흉내):
  - AR/AW/W 각 채널이 `READY`를 내리기까지 매 트랜잭션마다 0~5사이클 랜덤 지연.
  - R/B 채널의 `VALID`가 뜨기까지 0~5사이클 랜덤 지연.
  - **AWREADY와 WREADY가 서로 다른 사이클에, 순서 무관하게** 온다 — `axi4_master_dram.v`의 `aw_done`/`w_done` 독립 래치 로직이 정확히 이 케이스를 위해 있는 코드라 이 부분을 집중적으로 흔듦.
- 50라운드(길이 1~37워드, 랜덤 base) + 연속 10라운드(요청 사이 간격 없이 바로 이어붙임 — AXI 가변 레이턴시 하에서도 `S_IDLE` 레이스가 없는지 추가 확인)로 **쓰기 → 읽기 → 비교**.

### 결과

```
>>> PASS : axi4_master_dram bit-exact over 708 words, 50 rounds
```

### 뮤테이션 테스트 (테스트벤치 자체가 유효한지 검증)

`axi4_master_dram.v`의 읽기 데이터 캡처 한 줄을 일부러 고장냄:

```verilog
dram_rdata <= dram_rdata;  // BUG injected — m_axi_rdata 대신 자기 자신을 대입
```

동일한 테스트벤치로 재실행:

```
>>> FAIL : 708/708 word mismatches
```

**708/708 전부 실패로 잡아냄 — 테스트벤치가 실제로 결함을 검출한다는 것을 확인.** (프로젝트 컨벤션상 모든 테스트벤치는 뮤테이션 테스트를 거친다 — `README.md` §4 참고.)

## 6. `axi_lite_csr.v` — `done` 1사이클 펄스를 그대로 노출하는 문제

### 문제

`controller.v`의 `done`은 **딱 1사이클짜리 펄스**다:

```verilog
// controller.v
always @(posedge clk or posedge rst) begin
    if (rst) done <= 1'b0;
    else     done <= (state_q == ST_DONE);
end
```

그런데 수정 전 `axi_lite_csr.v`는 이 값을 그대로 AXI-Lite 읽기 데이터로 통과시켰다:

```verilog
// axi_lite_csr.v (수정 전)
s_axi_rdata <= (s_axi_araddr[5:2] == DONE_REG) ? {31'd0, done} : 32'd0;
```

100MHz에서 10ns 폭인 펄스를, PS가 AXI-Lite로 폴링해서 정확히 그 사이클에 맞춰 읽어낼 가능성은 사실상 0이다. `tb_top.v`/`tb_axi4_dma.v`는 이 레지스터를 아예 거치지 않기 때문에 지금까지 드러나지 않았던 문제다 — 이번에 `top_kv260.v`를 실제로 처음 구동해보면서 찾아냈다.

### 수정

**파일:** `axi_lite_csr.v` — `done`을 sticky latch로 감싸서, 다음 레이어의 start(`csr_addr==7` 쓰기)가 올 때까지 값을 유지하도록 함:

```verilog
// controller.v's `done` is a ONE-CYCLE pulse (done <= state_q==ST_DONE).
// At 100 MHz that is a 10 ns window; a PS polling loop reading this
// register over AXI-Lite has no realistic chance of ever sampling that
// exact cycle. Latch it here so software sees a level that stays high
// until it programs the NEXT layer (csr_addr 7 = start_pulse), which is
// exactly the point software has already observed the previous done and
// moved on - same convention tester.v uses internally (T_WAIT waits for
// the pulse, T_F0 immediately starts the next program's CSR writes).
reg done_latch;
always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if (!s_axi_aresetn)
        done_latch <= 1'b0;
    else if (done)
        done_latch <= 1'b1;
    else if (csr_we && csr_addr == 4'd7)
        done_latch <= 1'b0;
end
```

그리고 읽기 경로에서 `done` 대신 `done_latch`를 반환하도록 한 줄 교체.

### 검증 — `tb_axi_lite_csr.v` (신규)

`axi_lite_csr.v`를 AXI4-Lite 마스터 BFM으로 직접 구동:
- AW/W 채널을 서로 다른 사이클·순서로 랜덤하게 (같은 `fork/join` 독립 타이밍 패턴).
- BREADY/RREADY에 랜덤 백프레셔.
- 200회 랜덤 레지스터 쓰기(주소 0~9 순환 + 연속 20회 무간격 back-to-back) 전부 캡처해서 순서대로 비교.
- `done` 레지스터(0xF, 바이트주소 0x3C) 읽기 + 그 외 모든 주소가 0을 반환하는지 확인.

```
>>> PASS : axi_lite_csr bit-exact over 200 writes + readback checks
```

뮤테이션 테스트 (`DONE_REG`를 4'hF → 4'hE로 슬쩍 바꿔서 done 레지스터 주소 디코딩을 고장냄):

```
READ MISMATCH: done=1 expected 1, got 00000000
>>> FAIL : 1 error(s)
```

**정상적으로 잡아냄.**

> 테스트벤치를 처음 짤 때 AXI-Lite BREADY/RREADY를 세우기 **전에** BVALID/RVALID가 이미 떠 있는 fast-path 케이스(AW/W가 같은 사이클에 동시 수락되는 경우)를 놓쳐서 테스트벤치 자체가 데드락하는 버그가 있었다 (`@(posedge clk)`를 무조건 한 번 먼저 실행한 뒤에 `while(!bvalid)`를 검사했는데, 그 사이에 이미 bvalid가 뜨고 사라져버림). "ready를 올리자마자 먼저 확인하고, 아니면 기다린다" 순서로 고쳤다. 그리고 레지스터 인덱스를 바이트 주소로 변환할 때(`<<2`) 처음에 빠뜨려서 전부 엉뚱한 주소로 잡히는 테스트벤치 버그도 하나 있었다 — 둘 다 DUT가 아니라 테스트벤치 쪽 버그였고, 고치고 나니 PASS.

## 7. 새로 추가한 테스트 — `tb_top_kv260.v` (보드 실토폴로지 전체)

### 왜 필요한가

`tb_axi4_dma.v`와 `tb_axi_lite_csr.v`는 각 AXI 어댑터를 **따로** 검증한다. KV260에 실제로 올라가는 `top_kv260.v`는 이 둘 + `core.v`가 전부 같이 물려 있는데, 지금까지 이 조합 전체를 시뮬레이션해본 적이 없었다.

### 구성

**`Task_1_26_summer.srcs/sim_1/new/tb_top_kv260.v`** (신규)

- `top_kv260`을 통째로 인스턴스화. PS 역할은 테스트벤치가 직접 맡는다:
  - **AXI4-Lite 마스터**로 `dram.txt`에 인코딩된 CSR 프로그램을 `tester.v`가 하던 것과 동일한 순서로, 그러나 실제 AXI-Lite 쓰기로 재생(replay).
  - `csr_addr==7`(start) 쓰기 뒤에는 **37사이클 간격의 현실적인 폴링 루프**로 `done` 레지스터를 읽어 layer 완료를 확인 (하드웨어 폴링 주기와 고의로 안 맞는 소수 주기 — 우연히 펄스와 정렬돼서 통과하는 걸 방지).
- **AXI4 DDR 슬레이브 모델**(PS의 HP 포트)을 `tb_axi4_dma.v`와 같은 가변 레이턴시 BFM으로 구현하고, `dram.txt` 전체를 이 모델에 프리로드.
- 6개 레이어 전부 끝난 뒤, DDR 모델 내용을 `gold.txt`/`gold_addr.txt`와 직접 비교 (PS가 자기 DDR을 읽는 것과 동일한 방식).
- 진행 상황은 `heartbeat_kv260.txt`에 주기적으로 기록 (stdout 버퍼링으로 인한 가짜 행 문제를 피하기 위해 — §8 참고).

### 결과 — Layer 6 완료 직후 정지(hang) 발견

6개 레이어 전체를 재생하면 **Layer 1~6의 CNN 연산 자체는 매번 정상적으로 끝까지 도는데, Layer 6(Affine, 마지막 레이어)의 `core.done` 펄스가 뜬 바로 다음부터 시뮬레이션이 더 이상 진행되지 않는다.** 두 번의 독립된 전체 재생(cyc 기준 각각 다른 실행)에서 **동일하게** `core.done` 펄스 직후 정지가 재현됐다 — 우연이 아니라 결정적(deterministic) 현상.

```
cyc=1999510 ctrl=18 ...
cyc=1999511 ctrl=19 ...                         <- ST_DONE
cyc=1999512 ctrl=0  ... core_done=1             <- done 펄스, Layer 6 정상 완료
cyc=1999513 ctrl=0  ... core_done=0             <- 그 다음부터 아무 것도 안 바뀜
cyc=2019514 >>> STALL WATCHDOG: no state change for >20000 cycles, stopping
```

**디버깅 과정에서 기각한 가설들** (테스트 방식과 함께 기록):

1. **"레이어 6 자체가 고장났다"** → 기각. `ptr`을 프로그램 중간(레이어 6 시작 지점)으로 바로 점프시켜 레이어 6만 단독으로 재생해보면, `core.done`까지 약 43,000사이클 만에 깨끗하게 정상 완료된다. 레이어 6의 제어 로직(`controller.v`) 자체는 문제가 없다.
2. **"AXI-Lite 폴링 캡(cap)에 걸린 가짜 정지였다"** → 기각, 그리고 이건 내가 만든 테스트벤치 버그였다. 디버그용으로 `wait_done`에 폴링 횟수 상한(3000회)을 걸어뒀는데, Layer 2 하나만 해도 AXI 오버헤드 때문에 실제로 545,000사이클 이상 걸려서 상한을 초과해버린 것을 "정지"로 오인했다. 상한을 완전히 없애고(실제 `tb_top_kv260.v`와 동일하게 무제한 폴링) 다시 돌려서, 이게 진짜 정지가 아니었음을 확인했다.
3. **"CSR 프로그램의 종료 마커(0xE)를 못 찾고 무한 루프를 도는 것"** → 기각. `dram.txt`의 `PROG_BASE(0xEA80)`부터 직접 파싱해서 확인한 결과, Layer 6의 시작 명령(`0xF`, ptr=0x0eaf6) 바로 다음(ptr=0x0eaf8)에 정확히 종료 마커(`0000000e`)가 있다. 프로그램 인코딩·파싱 쪽 문제가 아니다.
4. **`axi4_master_dram.v`/`dma.v` 자체의 AXI4 프로토콜 결함** → 기각. `tb_axi4_dma_stress.v`로 랜덤 지연 범위를 넓히고(AR ready-delay 0~11사이클, AW/W 갭 0~7사이클, B delay 0~11사이클) 라운드 수를 5000회로 늘려 94,224워드를 스트레스 테스트했지만 **PASS**, 워치독(5000사이클 무변화 기준)도 트리거되지 않았다.
5. **`axi_lite_csr.v`의 폴링 자체가 데드락한다** → 기각. `tb_poll_stress.v`로 done 레지스터를 5만 번 연속 무간격으로 읽어도 **PASS**, 행(hang) 없음.

### 진짜 근본 원인 — RTL이 아니라 테스트벤치 자체의 Verilog `disable` 버그

AXI-Lite 채널 신호(`s_axi_ar/r/aw/w/b` valid·ready, `axi_lite_csr.v`의 내부 `rstate`/`wstate`/`done_latch`)를 워치독에 추가로 계측하고, `prog_loop`가 매 반복마다 실제로 어떤 `ptr`/`e_addr`/`e_data`를 읽는지 파일로 직접 로그를 남기도록 한 뒤 재실행해서 잡아냈다.

로그를 보면 Layer 6의 `done` 폴링까지는 전부 정상이다:

```
cyc=1956421 lyr=5 ptr=0x0000eaf6 word=0000000f e_addr=f e_data=00000001   <- Layer 6 start pulse
cyc=1999519 lyr=6 ptr=0x0000eaf8 word=0000000e e_addr=e e_data=00000000   <- 종료 마커(0xE) 정확히 찾음!
cyc=1999519 lyr=6 ptr=0x0000eafa word=00000000 e_addr=0 e_data=00000000  <- 그런데 안 멈추고 다음 엔트리로 계속 진행...
cyc=1999522 lyr=6 ptr=0x0000eafc word=00000000 e_addr=0 e_data=00000000
...
cyc=2008086 lyr=6 ptr=0x00010000 word=xxxxxxxx e_addr=x e_data=xxxxxxxx  <- DRAM_DEPTH(0x10000) 끝까지 넘어가 X로 진입
...
cyc=2242208 lyr=6 ptr=0x00033d1c word=xxxxxxxx e_addr=x e_data=xxxxxxxx  <- 계속 무한 증가, 끝없이 X를 읽으며 의미없는 AXI-Lite 쓰기를 반복
```

**종료 마커(0xE)는 정확한 사이클에 정확히 검출됐다.** 그런데도 루프가 멈추지 않은 이유는 테스트벤치 코드의 다음 패턴 때문이다:

```verilog
// 수정 전 (tb_top_kv260.v, tb_debug_layer6.v 둘 다 동일)
while (1) begin : prog_loop
    ...
    if (e_addr == 4'hE) begin
        $display("[TB] end of CSR program at ptr=0x%04h", ptr);
        disable prog_loop;     // <- 이게 while(1) 자체를 못 끊는다!
    end
    ...
end
```

Verilog에서 `disable <label>`은 **그 라벨이 붙은 블록만** 종료시킨다. 위 코드에서 `prog_loop`라는 라벨은 `while(1)`의 **몸체(한 번의 반복문)** 에 붙어 있다 — `while` 문 자체가 아니라. 그래서 `disable prog_loop`는 "이번 반복을 끝낸다"는 의미밖에 안 되고, 조건이 `while(1)`이니 그 다음 반복이 곧바로 다시 시작된다. 결과적으로 종료 마커를 제대로 찾고 "end of CSR program" 메시지까지 찍고도, 루프는 실제로는 절대 빠져나가지 못하고 **DRAM 나머지 영역(대부분 0)을 계속 CSR 레지스터 0번에 무의미하게 쓰고, `DRAM_DEPTH`(0x10000)를 넘어서면 배열 밖 X값을 영원히 읽으며 무의미한 AXI-Lite 쓰기를 계속** 한다 — 이게 AXI-Lite 채널이 계속 "살아서 토글"하고 있었기 때문에 상태-변화 기반 스톨 워치독도 못 잡아낸 이유였다. `#200_000_000`ns(2000만 사이클) 하드 타임아웃까지 가야 겨우 멈추는데, PASS/FAIL 검증 코드에는 영영 도달하지 못한다.

**즉, `dma.v`/`axi4_master_dram.v`/`axi_lite_csr.v`/`core.v`/`controller.v` 등 실제 RTL은 6개 레이어 전부 처음부터 끝까지 완벽하게 정상 동작하고 있었다.** 문제는 순수하게 이번에 새로 작성한 테스트벤치(`tb_top_kv260.v`, 그리고 그 디버그용 사본)의 종료 조건 코드에 있었다.

### 수정

`disable`이 실제로 `while` 루프 전체를 끊도록, 라벨을 `while` 문을 **감싸는** 블록에 붙인다:

```verilog
// 수정 후
ptr = PROG_BASE;
begin : prog_loop
while (1) begin
    e_addr = ddr_mem[ptr][3:0];
    e_data = ddr_mem[ptr+1];
    ptr = ptr + 2;
    if (e_addr == 4'hE) begin
        $display("[TB] end of CSR program at ptr=0x%04h", ptr);
        disable prog_loop;   // 이제 while(1) 전체를 정상적으로 빠져나감
    end else if (e_addr == 4'hF) begin
        ...
    end else begin
        ...
    end
end
end
```

**파일:** `Task_1_26_summer.srcs/sim_1/new/tb_top_kv260.v` (295~313행) — 동일한 수정을 디버그용 사본에도 적용.

### 검증 — 최종 PASS

수정한 테스트벤치로 6개 레이어 전체를 처음부터 재생한 결과:

```
===== LAYER 1 : start pulse sent, polling done =====
===== LAYER 1 : done =====
===== LAYER 2 : start pulse sent, polling done =====
===== LAYER 2 : done =====
===== LAYER 3 : start pulse sent, polling done =====
===== LAYER 3 : done =====
===== LAYER 4 : start pulse sent, polling done =====
===== LAYER 4 : done =====
===== LAYER 5 : start pulse sent, polling done =====
===== LAYER 5 : done =====
===== LAYER 6 : start pulse sent, polling done =====
===== LAYER 6 : done =====
[TB] end of CSR program at ptr=0x0000eafa
>>> PASS : top_kv260 (AXI-Lite CSR + AXI4 DDR) bit-exact (928 words)
```

**928/928 PASS.** 종료 마커를 만나자마자 `disable`이 `while(1)`을 정상적으로 빠져나가고, 곧바로 DDR 검증 단계로 넘어가 `gold.txt`/`gold_addr.txt`와 928워드 전부 일치를 확인했다. `top_kv260.v`(AXI-Lite CSR + AXI4 DDR 경로 + core.v + dma.v 전체 보드 토폴로지)가 이제 처음으로 끝까지 검증됐다.

## 8. 디버깅 메모 — Icarus stdout 버퍼링 함정

이번 회귀 테스트 중, `vvp` 출력을 파일로 리다이렉트한 채 백그라운드로 오래 돌리면 **stdout이 완전 버퍼링되어 프로세스가 실제로는 잘 진행 중인데도 로그 파일이 몇 시간째 그대로**인 것처럼 보이는 현상을 겪었다. 강제 종료(`taskkill /F`)하면 버퍼가 플러시되지 않아 그 구간의 출력이 통째로 유실된다.

**대응:** 콘솔 출력에 의존하지 않고, 테스트벤치 스스로 `$fopen`/`$fdisplay`/`$fclose`로 작은 heartbeat 파일에 주기적으로 진행 상황(`cyc`, 레이어 번호)을 **직접 파일 I/O로** 남기게 했다. 이건 stdout 파이프/버퍼와 무관한 별도 파일 핸들이라 실시간으로 확인 가능하다. 오래 걸리는 시뮬레이션을 백그라운드로 돌릴 때는 앞으로도 이 패턴을 쓸 것.

---

## 관련 파일

| 파일 | 상태 |
|------|------|
| `sources_1/new/dma.v` | 수정 (S_IDLE 가드 복원) |
| `sources_1/new/axi_lite_csr.v` | 수정 (`done` sticky latch) |
| `sim_1/new/tb_axi4_dma.v` | 신규 추가, PASS |
| `sim_1/new/tb_axi_lite_csr.v` | 신규 추가, PASS |
| `sim_1/new/tb_top_kv260.v` | 신규 추가, 수정 (`disable` 라벨 위치), **928/928 PASS** |
| `sim_1/new/tb_top.v` | 변경 없음, 928/928로 재확인 |
| (스크래치) `tb_axi4_dma_stress.v` | 격리 스트레스 테스트, 5000라운드/94,224워드 **PASS** — dma/axi4 자체는 무혐의 |
| (스크래치) `tb_poll_stress.v` | 격리 스트레스 테스트, 5만 회 연속 폴링 **PASS** — CSR 폴링 자체는 무혐의 |

## 9. KV260에 올리기 전 남은 작업

1. **Synthesis/Implementation 미실행** — 지금까지는 순수 behavioral 시뮬레이션. 배치·배선 후 타이밍 리포트 없음, 최대 동작 주파수 주장 불가 (`README.md` §5와 동일한 상태). `axi4_master_dram.v`/`axi_lite_csr.v`가 새로 추가한 로직이라 타이밍 클로저를 아직 아무것도 확인하지 않았다.
2. **실제 Zynq PS / Vitis 소프트웨어 스택과의 통합 미검증** — 이 테스트벤치는 PS 소프트웨어를 흉내낸 것이지 실제 드라이버/베어메탈 코드가 아니다.
3. **DDR 실제 타이밍 모델 아님** — AXI4 슬레이브 BFM은 0~5사이클 랜덤 지연으로 "가변 레이턴시"를 흉내낸 것으로, PS DDR 컨트롤러의 실제 레이턴시/버스트 특성과는 다르다.
4. 가능하면 **실보드에서 최종 확인** 후 비트스트림 플래시.
