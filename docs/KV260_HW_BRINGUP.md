# KV260 실보드 브링업 디버깅 기록

**날짜:** 2026-09-22 ~ 2026-09-23
**목표:** 시뮬레이션에서 928/928 PASS까지 검증된 CNN 가속기 RTL(`top_kv260.v`)을 실제 Kria KV260 보드에 올려서, PS(ARM Cortex-A53)가 AXI-Lite로 CSR을 제어하고 AXI4로 DDR에 접근하는 전체 시스템이 실제 하드웨어에서 동작하는지 검증.

**전제:** 이 문서에서 다루는 모든 문제는 RTL 로직 자체(`dma.v`, `axi_lite_csr.v`, `axi4_master_dram.v`, `core.v`, `controller.v`)와는 무관함. 그 부분은 이미 `Task_2_26_summer_CNN` 쪽 `DMA_AXI_FIX.md`에서 시뮬레이션으로 928/928 PASS까지 완전히 검증 끝난 상태였음. 여기서 찾은 문제들은 전부 **① Vivado 블록디자인(보드 배선) 설정, ② Vitis 플랫폼/빌드 툴체인, ③ 디버깅 방법론** 레벨의 이슈였음.

---

## 목차

1. IP 패키징 및 블록디자인 구성
2. 문제 1 — UART 출력이 전혀 안 뜸 (MIO 미설정)
3. 문제 2 — Vitis 플랫폼이 Vivado에서 새로 만든 XSA를 계속 옛날 걸로 인식 (캐시 문제)
4. 문제 3 — 리셋 극성(polarity) 버그: `top_kv260_0`이 계속 리셋 상태
5. 문제 4 — `dcm_locked` 미연결로 리셋이 영원히 안 풀림
6. 문제 5 — Vivado 배선 실수로 5개 리셋 핀 연쇄 단선
7. 문제 6 — FSBL 링크 실패 (`psu_init_gpl.c` 중복 심볼) — 내가 만든 실수
8. 문제 7 (미해결/진행 중) — CSR 첫 레지스터 쓰기에서 CPU가 완전히 멈춤 (AXI 버스 레벨 hang)
9. 디버깅 방법론 요약
10. 현재 상태 및 남은 작업

---

## 1. IP 패키징 및 블록디자인 구성

`top_kv260.v`(RTL 최상위, `axi_lite_csr.v` + `axi4_master_dram.v` + `top.v`를 감싼 보드용 wrapper)를 Vivado IP Integrator에서 쓸 수 있도록 **Tools → Create and Package New IP**로 패키징.

- IP 저장 위치: `<vivado_proj>/ip_repo/top_kv260_v1` (프로젝트 루트에 직접 안 두고 별도 `ip_repo` 폴더로 분리 — `.xpr`/자동생성 폴더와 섞이지 않게 하려는 목적)
- Vivado가 `s_axi_*`, `m_axi_*` 네이밍 컨벤션을 자동 인식해서 AXI4-Lite(`s_axi`)/AXI4(`m_axi`) 인터페이스로 자동 묶어줌
- `m_axi`에 `AWLEN/AWSIZE/AWBURST/WLAST` 등 버스트 신호가 있어서 AXI4(full)로, `s_axi`엔 없어서 AXI4-Lite로 정확히 자동 분류됨 (RTL 포트 구성만으로 Vivado가 프로토콜 판별)
- Addressing and Memory: `s_axi`의 `reg0` 주소블록 Range가 기본값 `4096`(0x1000)으로 잡혔는데, 실제 `axi_lite_csr.v`는 `ADDR_WIDTH=6`(64바이트)만 씀 — 남는 공간은 그냥 예약만 되고 실제 디코드에 안 쓰이므로 **기능적으로는 문제없음**, 그대로 둠

블록디자인 구성:
- Zynq UltraScale+ MPSoC PS 블록 + `top_kv260_0`(방금 만든 IP) + `axi_smc`(SmartConnect, DDR 경로용) + `ps8_0_axi_periph`(AXI Interconnect, CSR 경로용) + `rst_ps8_0_96M`(Processor System Reset)
- `top_kv260_0.s_axi` → `ps8_0_axi_periph` → PS의 `M_AXI_HPM0_FPD` (CSR 제어)
- `top_kv260_0.m_axi` → `axi_smc` → PS의 `S_AXI_HPC0_FPD` (DDR 접근)

---

## 2. 문제 1 — UART 출력이 전혀 안 뜸

### 증상
FSBL은 정상 실행되는데(JTAG 다운로드 로그상 성공), `xil_printf`로 찍은 텍스트가 Serial Terminal에 **아무것도 안 뜸**. COM6, COM7 둘 다 연결해봐도 침묵.

### 원인 진단
장치관리자에서 `USB Serial Converter A/B/C/D`(FTDI 4채널 칩)와 `USB Serial Port (COM6/COM7)`이 정상적으로 잡혀있는 건 확인됨 → USB 배선/드라이버 문제 아님.

Vivado에서 PS 블록의 **I/O Configuration → UART** 확인해보니 **UART0, UART1 둘 다 체크 안 돼있었음**. Zynq UltraScale+의 UART 등 주변장치는 **MIO(Multiplexed I/O)** 크로스바를 통해 소프트웨어(RTL 설계 단계)에서 명시적으로 물리 핀에 배정해줘야 함 — 자동으로 아무 핀에나 나가는 게 아님. 체크 자체가 안 돼있었으니 PS가 UART 신호를 물리 핀으로 아예 안 내보내고 있었던 것.

### 근본 원인
이 프로젝트는 Vivado 프로젝트 생성 시 **KV260 보드 프리셋(Board file)을 쓰지 않고 칩 파트 번호(xck26...)만 직접 지정**해서 시작됨. 보드 프리셋을 썼다면 Vivado가 "이 보드는 UART1이 실제로 MIO 36/37에 배선돼있다"는 정보를 이미 알고 있어서 자동으로 켜줬을 텐데, 커스텀 파트 방식이라 아무것도 자동 설정 안 됨 — 사람이 직접 알려줘야 했음.

### 수정
- PS Re-customize IP → I/O Configuration → UART → **UART 1** 체크
- MIO 핀 수동 지정: **MIO 36 .. 37** (Kria K26 SOM의 표준 UART1 라우팅)
- Board 탭이 없어서(보드 프리셋 미사용 프로젝트) 자동 배정 불가, 수동으로 맞는 MIO 페어 선택 (MIO 페어는 0-1, 4-5, 8-9 ... 36-37 처럼 4단위로만 선택 가능 — 아무 숫자나 못 고름)

### 검증
Generate Bitstream 이후 새 XSA를 Vitis 플랫폼에 반영하고, BSP(`system.mss`)에서 `stdin`/`stdout`이 `psu_uart_1`로 자동 설정됨 확인. 이후 실행하니 Serial Terminal에 `Xilinx Zynq MP First Stage Boot Loader`, `=== KV260 CNN accelerator test ===` 등 실제 텍스트가 뜸 — **UART 문제 해결 확인**.

---

## 3. 문제 2 — Vitis 플랫폼이 새 XSA를 계속 못 알아봄 (캐시 문제)

### 증상
Vivado에서 UART 고치고 → Generate Bitstream → Export Hardware까지 다 했는데, Vitis에서 `CNN_KV260 [Platform]` 우클릭 → **Clean → Build**를 여러 번 눌러도 **BSP(`xparameters.h`)에 UART 관련 항목이 하나도 안 생김**. 실행해봐도 여전히 UART 침묵.

### 진단 방법
GUI를 못 믿고 **파일 타임스탬프와 md5 체크섬을 직접 비교**하는 방식으로 전환:

```bash
# Vivado가 export한 최신 XSA
ls -la --time-style=full-iso <vivado_proj>/CNN_KV260_wrapper.xsa

# Vitis 플랫폼이 실제로 참조하는 XSA (소스)
ls -la --time-style=full-iso <vitis_ws>/CNN_KV260/hw/CNN_KV260_wrapper.xsa

# 실행 시 보드에 실제로 올라가는 비트스트림
ls -la --time-style=full-iso <vitis_ws>/kv260_test/_ide/bitstream/CNN_KV260_wrapper.bit
md5sum <위 파일들>
```

→ Vivado 쪽은 최신인데, Vitis 플랫폼의 `hw/` 폴더 안 XSA는 **몇 시간 전 옛날 파일 그대로**인 걸 확인. GUI의 "Platform 우클릭 → Clean/Build"가 XSA 파일 자체를 다시 읽어들이는 걸 신�일하게 트리거 안 함 (Vitis 2022.1의 알려진 동작 이슈).

### 해결 방법
GUI를 거치지 않고 **XSA/비트스트림 파일을 직접 강제로 덮어씀**:

```bash
HW=".../workspace/CNN_KV260/hw"
NEW="<vivado_proj>/CNN_KV260_wrapper.xsa"
cp "$HW"/CNN_KV260_wrapper.xsa "$HW/_bak_날짜/"   # 백업
unzip -o "$NEW" -d /tmp/extracted                  # 새 XSA 안의 psu_init.c 등도 함께 추출
cp "$NEW" "$HW/CNN_KV260_wrapper.xsa"
cp /tmp/extracted/psu_init.* "$HW/"
```

이후 Vitis에서 Refresh(F5) → Clean → Build 하면 그제서야 제대로 반영됨. 최종적으로 **비트스트림/XSA/FSBL 각 단계 파일을 md5로 대조하는 체크리스트**를 만들어서, 매번 "진짜 최신인지" 확인 후에만 보드에 올리는 방식으로 작업 신뢰도를 확보함.

### 교훈
Vitis GUI의 "Clean/Build"만 믿지 말고, **실제 파일 시스템의 타임스탬프/체크섬**으로 검증하는 게 훨씬 확실함. 이 프로젝트 내내 반복적으로 발생한 문제라, 매번 비트스트림을 바꿀 때마다 이 방식으로 재확인하는 루틴을 만듦.

---

## 4. 문제 3 — 리셋 극성(polarity) 버그 (핵심 버그 #1)

### 증상
UART 고친 후에도 여전히 첫 CSR 레지스터 쓰기(`REG(0) = ...`)에서 프로그램이 멈춤. `=== KV260 CNN accelerator test ===`까지는 뜨는데 그 다음(`Layer 1 config written...`)이 절대 안 뜸.

### 진단
`top_kv260.v` RTL을 다시 읽어봄:

```verilog
// top_kv260.v : 11번째 줄
input                        rst,              // active HIGH (from PS FCLK_RESET0_N, inverted)
...
// 71-75번째 줄
// NOTE: s_axi_aresetn is active LOW (AXI convention), rst here is active
// HIGH (matches core.v/dma.v). Board-level reset wiring must invert once;
// this module inverts it right here so both sub-blocks see the polarity
// they each expect.
wire s_axi_aresetn = ~rst;
```

`top_kv260.v`의 `rst` 포트는 **active-HIGH**를 기대하도록 설계돼있음(내부에서 직접 반전시켜서 씀). 그런데 Vivado Tcl Console로 실제 배선을 확인해보니:

```tcl
get_bd_pins -of_objects [get_bd_nets -of_objects [get_bd_pins top_kv260_0/rst]]
```

`peripheral_aresetn`(active-LOW, Processor System Reset IP의 출력)에 **직결**돼있었음. 이러면 정상 동작 시(리셋 안 걸린 상태) `peripheral_aresetn=1`인데, `top_kv260.v` 입장에서는 `rst=1`을 "리셋 걸렸다"로 해석해버려서 **영원히 리셋 상태**로 있었던 것 — 극성이 반대로 물린 전형적인 버그.

### 수정
`rst_ps8_0_96M`(Processor System Reset) IP에는 active-LOW(`peripheral_aresetn`) 뿐 아니라 **active-HIGH 출력(`peripheral_reset`)도 별도로 존재**함 — 이걸로 재배선:

```
rst_ps8_0_96M.peripheral_reset[0:0]  →  top_kv260_0.rst
```

### 검증 (Tcl로 배선 재확인)
```tcl
get_bd_pins -of_objects [get_bd_nets -of_objects [get_bd_pins top_kv260_0/rst]]
→ /rst_ps8_0_96M/peripheral_reset /top_kv260_0/rst
```
정확히 연결됨 확인.

---

## 5. 문제 4 — `dcm_locked` 미연결로 리셋이 영원히 안 풀림

### 증상
리셋 극성을 고쳤는데도 **증상이 똑같음** (여전히 첫 CSR 쓰기에서 멈춤). 비트스트림/XSA md5까지 다 맞춰서 확인했는데도 재현.

### 진단
`rst_ps8_0_96M`의 입력 포트들을 Tcl로 하나씩 점검하던 중, **`dcm_locked` 입력에 아무 것도 연결이 안 돼있는 걸(CONNECTIONS 블록 자체가 없음) 발견**:

```
<PORT DIR="I" NAME="dcm_locked" SIGIS="undef"/>   <!-- CONNECTIONS 없음 -->
```

`proc_sys_reset` IP는 `dcm_locked`(클럭이 lock됐는지)이 1이 될 때까지 내부적으로 리셋 출력을 계속 유지하는 구조임. 이 핀이 연결 안 되면 Vivado가 기본으로 **0으로 tie-off**해버리기 때문에, 클럭 소스에 실제 MMCM/PLL이 없는 이 설계(PS 클럭을 그대로 씀, 별도 클럭 생성 IP 없음)에서는 `dcm_locked`가 영원히 0으로 묶여서 **리셋 출력 자체가 절대 안 풀리는** 상황이었음.

### 수정
IP Catalog에서 **Constant** (`xlconstant`) IP 추가, Width=1, Value=1로 설정해서 `dcm_locked`에 연결 — "클럭은 항상 락 상태"라고 고정으로 알려줌 (실제 클럭 생성 IP가 없는 설계에서 표준적으로 쓰는 방법).

```
xlconstant_0.dout[0:0]  →  rst_ps8_0_96M.dcm_locked
```

### 검증
```tcl
get_bd_pins -of_objects [get_bd_nets -of_objects [get_bd_pins rst_ps8_0_96M/dcm_locked]]
→ /xlconstant_0/dout /rst_ps8_0_96M/dcm_locked
```

---

## 6. 문제 5 — Vivado 배선 실수로 5개 리셋 핀 연쇄 단선

### 경위
문제 3을 고치는 과정에서, `top_kv260_0.rst`에 연결된 **기존 배선(옛날 `peripheral_aresetn` 연결)을 캔버스에서 선을 클릭해서 삭제**했는데, Vivado IP Integrator에서 하나의 net이 여러 핀에 팬아웃(fan-out)돼있을 때 트렁크 선을 잘못 잡고 지우면 **그 net에 물려있던 다른 핀들까지 한꺼번에 전부 끊김**.

### 증상 확인
Validate Design (F6) 돌렸더니:

```
[BD 41-759] The input pins (listed below) are either not connected or do not have a source port...
/ps8_0_axi_periph/ARESETN
/ps8_0_axi_periph/S00_ARESETN
/ps8_0_axi_periph/M00_ARESETN
/ps8_0_axi_periph/S01_ARESETN
```

`axi_smc.aresetn`도 같이 끊겨있던 걸 육안으로 추가 확인.

### 수정
`rst_ps8_0_96M.peripheral_aresetn[0:0]`에서 위 5개 핀 전부 다시 수동으로 재배선.

### 교훈
Vivado IP Integrator에서 **팬아웃된 net의 일부만 지우고 싶을 때는, 지우려는 그 핀-핀 구간만 정확히 선택**해야 함(트렁크를 잡으면 전체 net이 날아감). 재배선 후에는 반드시 Validate Design으로 "disconnected pin" 경고가 없는지 재확인하는 걸 습관화함.

---

## 7. 문제 6 — FSBL 링크 실패 (`psu_init_gpl.c` 중복 심볼) — 직접 만든 실수

### 경위
문제 2(XSA 캐시 문제)를 해결하려고 Vivado가 export한 XSA 안의 `psu_init.c`/`psu_init.h`/`psu_init.tcl`뿐 아니라 **`psu_init_gpl.c`/`psu_init_gpl.h`도 같이 복사**해서 Vitis 플랫폼의 `zynqmp_fsbl/` 폴더에 강제로 밀어넣었음.

### 증상
FSBL 빌드 로그에서:

```
make: *** [Makefile:27: fsbl_a53.elf] Error 1
...multiple definition of `psu_pll_init_data'; psu_init.o (symbol from plugin):(.text+0x0): first defined here
...multiple definition of `psu_init'; ...
```

FSBL의 개별 `.o` 파일들은 전부 정상 컴파일됐는데, **최종 링크 단계에서 실패**해서 `fsbl_a53.elf` 자체가 아예 안 만들어짐(디렉토리에 파일 자체가 없었음).

### 원인
`psu_init.c`와 `psu_init_gpl.c`는 **같은 내용을 다른 라이선스 조건으로 담은 대체 버전 파일**로, 원래 프로젝트에는 둘 중 하나만 있어야 함. Vitis 빌드 시스템이 폴더 안의 `.c` 파일을 자동으로 전부 컴파일 대상에 포함시키는데, 내가 실수로 두 파일을 같은 폴더에 같이 넣는 바람에 **`psu_init()`, `psu_pll_init_data()` 등 똑같은 함수/전역변수가 두 번 정의**돼서 링커가 "multiple definition" 에러를 낸 것.

### 수정
```bash
rm zynqmp_fsbl/psu_init_gpl.c zynqmp_fsbl/psu_init_gpl.h zynqmp_fsbl/psu_init_gpl.o zynqmp_fsbl/psu_init_gpl.d
```
`psu_init.c`만 남기고 플랫폼 Clean → Build 다시 하니 `fsbl_a53.elf` 정상 생성됨.

### 검증
링커 로그 파일(`.log/CNN_KV260_.build.ui.log`)을 직접 읽어서 정확한 에러 원인(중복 심볼 목록)을 확인한 뒤 수정 — GUI 에러 팝업("Error 1")만으로는 원인을 알 수 없어서, 실제 빌드 로그를 파일로 직접 열어서 진짜 원인을 찾아낸 케이스.

---

## 8. 문제 7 (미해결/진행 중) — CSR 첫 레지스터 쓰기에서 CPU가 완전히 멈춤

### 증상
문제 3~6을 전부 고친 뒤에도 **여전히 첫 CSR 레지스터 쓰기에서 멈춤**, 증상 자체는 처음부터 끝까지 한 번도 안 바뀜.

### 디버거로 직접 확인한 사실
Debug 뷰에서 **Suspend(일시정지)를 시도했더니**:
```
Error: Cannot suspend: TCF error report:
Error text: Cannot halt processor core, timeout
```
XSCT 콘솔에서 직접 `stop` 명령을 쳐도 동일하게 **"Cannot halt processor core, timeout"**.

이건 소프트웨어 무한루프(디버거로 언제든 멈출 수 있음)가 아니라, **CPU 코어 자체가 AXI 버스 트랜잭션 도중 진짜로 물려서(bus lock) 디버그 인터럽트조차 못 받는 상태**라는 뜻. 즉 소프트웨어 버그가 아니라 하드웨어(RTL 또는 배선) 레벨에서 AXI 응답이 영원히 안 돌아오는 상황.

### 기각한 가설들 (진단 과정)

| 가설 | 확인 방법 | 결과 |
|---|---|---|
| PS-PL 격리(isolation)가 안 풀림 | `psu_init.tcl`에서 `psu_ps_pl_isolation_removal`, `psu_ps_pl_reset_config` proc을 XSCT에서 직접 호출 | 실행은 됐지만 halt 여전히 실패 → 기각 |
| 배선 실수로 `s_axi` 자체가 끊김 | `get_bd_intf_pins -of_objects [get_bd_intf_nets -of_objects [get_bd_intf_pins top_kv260_0/s_axi]]` | `ps8_0_axi_periph/M00_AXI`에 정상 연결 확인 → 기각 (참고: 처음엔 `get_bd_nets`로 개별 신호를 조회해서 전부 빈 값이 나와 "끊겼다"고 오판할 뻔했는데, `s_axi`가 **번들 인터페이스 핀**이라 개별 신호 단위로는 원래 net이 안 잡히는 것뿐이었음 — `get_bd_intf_*` 계열 명령으로 다시 확인해서 false alarm임을 정정) |
| 타이밍 위반(setup/hold) | Implementation 완료 후 **Timing Summary** 리포트 확인 | WNS = +2.052ns, WHS = +0.014ns, 실패 endpoint 0개, "All user specified timing constraints are met." → 기각 |

### 현재 시도 중인 가설
PS의 `M_AXI_HPM0_FPD` 마스터 포트가 **128비트 폭**으로 설정돼있는데, `axi_lite_csr.v`는 32비트 AXI4-Lite임. 이 폭 차이를 Vivado가 자동으로 끼워넣은 `auto_ds`(자동 데이터폭 변환기)가 메꾸는 구조인데, 계속 반복해서 나오던 다음 경고가 사실 무해한 게 아니라 **B채널(쓰기 응답) 자체가 안 돌아오는 원인**일 수 있다고 의심:

```
WARNING: [BD 41-237] Bus Interface property AWUSER_WIDTH does not match between
/ps8_0_axi_periph/s00_couplers/auto_ds/S_AXI(0) and /zynq_ultra_ps_e_0/M_AXI_HPM0_FPD(16)
```

**조치:** PS Re-customize → PS-PL Configuration → PS-PL Interfaces → Master Interface → **AXI HPM0 FPD Data Width를 128 → 32bit로 변경**, 폭변환기 자체가 안 생기게 만듦. 비트스트림 재생성 후 검증 예정 (이 문서 작성 시점 기준 Implementation 진행 중).

### 이것도 실패할 경우 다음 후보 (우선순위 순)
1. **Vivado Hardware Manager로 직접 프로그래밍** (Vitis의 JTAG 다운로드 대신) — 비용 없음, PS-PL 후처리 시퀀스가 다를 가능성
2. `ps8_0_axi_periph`(AXI Interconnect, 구형 IP)를 걷어내고 CSR 경로도 **`axi_smc`(SmartConnect)로 통일** — DDR 경로에서 이미 검증된 컴포넌트
3. **ILA(Integrated Logic Analyzer)**를 `axi_lite_csr.v`의 `s_axi_*` 신호에 직접 붙여서 실제 하드웨어 파형을 관찰 — 추측이 아니라 확정적 원인 규명

---

## 8-1. 문제 7 해결 — 진짜 근본 원인: PS-PL isolation 미해제 + fabric reset 미해제

### 폭 변환기 가설도 기각
`M_AXI_HPM0_FPD`를 32bit로 바꾼 비트스트림에서도 **증상 완전히 동일** → 기각.

### 결정적 단서 1: 브레이크포인트 + 단계실행
비동기 Suspend는 이미 버스에 물린 뒤라 실패했으므로, **`REG(0)` 줄에 미리 브레이크포인트**를 걸고 F6으로 한 줄씩 실행. `REG(0)`~`REG(4)`는 통과하고 **`REG(5)`에서 정지**.
- 해석: A53은 PL 주소를 Device-nGnRE(버퍼링 허용)로 매핑 → 쓰기를 write buffer에 쌓고 계속 진행 → 버퍼가 차는 5번째에서 정지. **즉 BRESP가 단 한 번도 안 돌아오고 있었음.** 앞 4개는 버퍼링에 가려졌던 것뿐.

### 결정적 단서 2: CPU 우회 JTAG DAP 직접 접근
XSCT에서 `loadhw`로 메모리맵을 올린 뒤 DAP으로 직접:
```
mwr 0xa0000000 0x12345678  → AP transaction timeout
mrd 0xa0000000             → AXI AP transaction error, DAP status 0x30000021
```
→ **CPU/MMU/소프트웨어 문제 완전 배제. PL이 AXI에 아예 응답 안 함.**
(주의: 이 에러 후 DAP sticky 에러 비트가 남아 **모든 타겟이 `Cannot open JTAG port`** 로 잠김 → 보드 전원 재인가로만 복구 가능했음)

### PS 레지스터로 PL 상태 점검 (전부 XSCT `mrd`, 비트스트림 불필요)
| 레지스터 | 주소 | 값 | 의미 |
|---|---|---|---|
| GPIO `DATA_5` | 0xFF0A0054 | `0x00000000` | **bit31=0 → `pl_resetn0`(EMIO GPIO[95]) assert 상태** |
| `REQ_PWRUP_STATUS` | 0xFFD80110 | `0x00000000` | PL power-up 요청 완료 |
| `PL0_REF_CTRL` | 0xFF5E00C0 | `0x01010A00` | CLKACT=1, 100MHz 정상 |

### 블록디자인 클럭 재검증
`maxihpm0_fpd_aclk`, `saxihpc0_fpd_aclk`, IP `clk`, interconnect, smartconnect 전부 `pl_clk0`에 연결됨 (Tcl `get_bd_nets`로 확인) → 기각.

### 결정적 단서 3: XSCT 수동 초기화 시퀀스로 성공
```tcl
rst -system
source psu_init.tcl
psu_init
psu_ps_pl_isolation_removal      ;# ← Vitis 디버그 런치는 이걸 안 함
fpga -file CNN_KV260_wrapper.bit
psu_ps_pl_reset_config           ;# ← 이것도 안 함
mwr 0xa0000000 0x00060001  ... (설정 레지스터 9개)
mwr 0xa000001c 1           ;# start
mrd 0xa000003c             → 00000001  (done)
```
**처음으로 실보드에서 가속기가 레이어 1을 완주**. AXI-Lite(`s_axi`) CSR 경로와, `done`까지 가려면 반드시 거쳐야 하는 AXI4(`m_axi` → HPC0 → DDR) DMA 경로 둘 다 동작 확인.

### 근본 원인
`psu_init.c`의 `psu_ps_pl_isolation_removal_data()`와 `psu_ps_pl_reset_config_data()`는 **`xfsbl_partition_load.c` / `xfsbl_handoff.c`에서만 호출**됨 — 즉 FSBL이 **부팅 이미지(BOOT.BIN)에서 PL 파티션을 로드할 때만** 실행됨. Vitis JTAG 디버그 런치는 비트스트림을 XSCT `fpga -file`로 FSBL 밖에서 직접 굽고 ELF만 다운로드하므로 이 경로를 절대 안 탐 → PS-PL 격리 유지 + fabric reset assert 유지 → PL이 AXI에 영원히 무응답.

앞서 고친 리셋 극성(문제 3), `dcm_locked`(문제 4)는 **실제로 있던 버그가 맞지만**, 이 상위 원인에 가려져 수정 효과가 보이지 않았던 것.

### 수정 (앱 코드, 비트스트림 재생성 불필요)
`main()` 첫 부분에서 FSBL이 안 해준 두 단계를 직접 수행:
```c
static int remove_ps_pl_isolation(void)
{
    int guard = 100000;
    Xil_Out32(0xFFD80118U, (Xil_In32(0xFFD80118U) & ~0x00800000U) | 0x00800000U); // REQ_PWRUP_INT_EN.PL
    Xil_Out32(0xFFD80120U, (Xil_In32(0xFFD80120U) & ~0x00800000U) | 0x00800000U); // REQ_PWRUP_TRIG.PL
    while (((Xil_In32(0xFFD80110U) & 0x00800000U) != 0U) && (--guard > 0)) {       // pending until 0
        ;
    }
    return (guard > 0);
}

static void release_pl_fabric_reset(void)   // pl_resetn0 = EMIO GPIO[95] = bank5 bit31
{
    Xil_Out32(0xFF0A002CU, (Xil_In32(0xFF0A002CU) & ~0xFFFF0000U) | 0x80000000U); // MASK_DATA_5_MSW
    Xil_Out32(0xFF0A0344U, 0x80000000U);   // DIRM_5
    Xil_Out32(0xFF0A0348U, 0x80000000U);   // OEN_5
    Xil_Out32(0xFF0A0054U, 0x80000000U);   usleep(1000);
    Xil_Out32(0xFF0A0054U, 0x00000000U);   usleep(1000);
    Xil_Out32(0xFF0A0054U, 0x80000000U);   usleep(1000);
}
```
레지스터 주소/값은 전부 XSA에 들어있는 `psu_init.tcl`에서 그대로 가져옴(추측한 주소 없음).

> 중간 실수: 처음엔 폴링 조건을 `== 0U`로 잘못 써서(`psu_init.c` 원본 `mask_pollOnValue(..., 0x00000000)`은 "0이 될 때까지 대기") 수정. 또 `kv260_test1/_ide/psinit/psu_init.tcl`이 옛날 하드웨어 버전으로 남아있어 현재 XSA 버전으로 교체.

### 최종 검증 — 실보드 출력 (2026-09-29)
```
=== KV260 CNN accelerator test ===
PS-PL isolation removed (PWRUP_STATUS = 0x00000000)
PL fabric reset released (GPIO DATA_5 = 0x80000000)
Layer 1 config written. Starting...
>>> PASS: Layer 1 done detected.
```
**Vitis 앱 단독으로(XSCT 수동 조작 없이) 실보드에서 CSR 제어 + 레이어 1 완주 성공.**

### 기타 겪은 것
- 전원 재인가 직후 UART에 `pxelinux.cfg`, `ethernet@ff0e0000 Waiting for PHY auto negotiation` 출력 → KV260 QSPI의 공장 U-Boot가 네트워크 부팅 시도하는 것, 무관. Vitis Run 시 `rst -system`으로 끊김.
- 장시간 Vivado+Vitis+XSCT 동시 실행 후 Vivado `Internal Exception`(`시스템 리소스가 부족하기 때문에…`) → 설계 무관, PC 자원 고갈. 결과물이 이미 파일로 나와있어 Vivado 종료로 해결.

---

## 8-2. 최종 검증 — 실보드 6레이어 전체 실행, 928/928 PASS

### 사전 작업: 앱 메모리 위치 이동
`axi4_master_dram.v`는 `DDR_BASE = 0x0000_0000`, 즉 DMA 워드 주소 `w` ↔ DDR 바이트 주소 `4*w` → DMA가 DDR `0x0 ~ 0x3FFFC`를 사용. 그런데 기본 링커 스크립트는 앱 ELF도 `0x0`부터 올림 → 이미지 로드 시 실행 중인 프로그램을 덮어씀. `lscript.ld`에서 `psu_ddr_0_MEM_0`의 ORIGIN을 `0x1000_0000`으로 이동 (비트스트림 재생성 불필요).

### 테스트 프로그램 구성 (`kv260_test1/src/main.c`)
1. PS-PL isolation 해제 + fabric reset 해제 (8-1절)
2. `Xil_DCacheDisable()` — DMA가 CPU 캐시 모르게 DDR을 읽고 쓰므로 CPU 접근을 전부 uncached로
3. `dram.txt`(입력 이미지 + 가중치 + BN 파라미터 + CSR 프로그램, 65536워드)를 `dram_img.h`로 변환해 앱에 내장 → DDR `0x0`에 복사 후 전체 readback 검증
4. `PROG_BASE(0xEA80)`의 CSR 프로그램을 `tester.v` / `tb_top_kv260.v`와 동일한 규칙으로 재생 (`0xF` = start + done 폴링, `0xE` = 종료), 레이어별 시간 `XTime`으로 측정
5. `gold_addr.txt`/`gold.txt`(928워드)를 `gold.h`로 내장, DDR 결과와 비교

데이터 파일은 시뮬레이션 928/928 PASS 때 쓴 것과 md5 동일한 파일 사용 (`dram.txt` md5 `631f7273...`).

### 실보드 출력 (2026-09-29)
```
=== KV260 CNN accelerator : full 6-layer run ===
PS-PL isolation removed, PL fabric reset released
DDR image loaded: 65536 words @ 0x00000000, readback mismatches = 0
Layer 1 done  (3112 us)
Layer 2 done  (19542 us)
Layer 3 done  (11057 us)
Layer 4 done  (20799 us)
Layer 5 done  (12546 us)
Layer 6 done  (1524 us)
All 6 layers done in 68846 us
>>> PASS: 928/928 golden words match on KV260 hardware
```

**RTL 시뮬레이션(928/928) → 실보드(928/928) 비트 단위 완전 일치.**

### 레이어별 실행 시간 (PL 100MHz)
| 레이어 | 실보드 (µs) | 시뮬레이션 추정 (µs)* | 비율 |
|---|---|---|---|
| 1 Conv1_1 | 3,112 | ~1,200 | ~2.6× |
| 2 Conv1_2 | 19,542 | ~5,500 | ~3.6× |
| 3 Conv2_1 | 11,057 | ~3,400 | ~3.3× |
| 4 Conv2_2 | 20,799 | ~6,000 | ~3.5× |
| 5 Conv3 | 12,546 | ~3,700 | ~3.4× |
| 6 Affine | 1,524 | ~350 | ~4.4× |
| **합계** | **68,846** | **~20,000** | **~3.4×** |

\* `tb_top_kv260.v` 누적 사이클(AXI4 슬레이브 BFM, 응답 지연 0~5사이클)에서 레이어 경계로 추정한 값.

**해석:** 실보드가 일관되게 약 3~4배 느림. `axi4_master_dram.v`가 **버스트 길이 1(단일 워드) 트랜잭션**만 내기 때문에, 실제 PS DDR 컨트롤러의 워드당 왕복 지연(BFM의 0~5사이클보다 훨씬 김)이 그대로 전체 시간에 곱해짐. 연산은 정확하지만 메모리 대역폭이 병목 → **AXI4 버스트 전송(AWLEN/ARLEN > 0) 도입이 가장 큰 성능 개선 포인트**.

---

## 9. 디버깅 방법론 요약

이번 브링업 과정에서 일관되게 사용한 방법:

1. **GUI 상태를 신뢰하지 않고 파일 시스템을 직접 검증** — Vitis의 "Clean/Build"가 여러 번 실제로 파일을 갱신 안 하는 걸 겪었기 때문에, 매 단계마다 `ls -la --time-style=full-iso`로 타임스탬프, `md5sum`으로 체크섬을 대조해서 "진짜 최신인지" 확인 후에만 다음 단계로 진행
2. **RTL 주석과 실제 배선을 항상 대조** — `top_kv260.v`의 극성 관련 주석(`// active HIGH`)을 실제 Vivado 블록디자인 배선과 Tcl로 교차검증해서 리셋 버그 발견
3. **Vivado Tcl Console로 배선을 정확하게 질의** — 그림(다이어그램)만 보고 연결 상태를 판단하면 오판 가능(예: 겹친 선, 지나간 선) → `get_bd_pins`/`get_bd_nets`/`get_bd_intf_pins`/`get_bd_intf_nets`로 텍스트 기반 정확한 확인. 단, **번들 인터페이스 핀은 개별 신호 net 조회가 안 통한다**는 것도 이번에 직접 겪고 알게 됨 (`get_bd_intf_*` 계열을 따로 써야 함)
4. **디버거의 "Suspend 실패"를 정보로 활용** — 단순히 안 멈춘다고 포기하지 않고, "Cannot halt: timeout"이라는 에러 메시지 자체가 "소프트웨어 루프가 아니라 진짜 버스 레벨 hang"이라는 중요한 진단 정보였음
5. **무료로 확인 가능한 것부터 소거법으로 좁힘** — 비트스트림을 다시 굽는 건 시간이 오래 걸리므로, PS-PL 격리(Tcl로 무료 확인), 배선 연결성(Tcl로 무료 확인), 타이밍(리포트로 무료 확인)을 먼저 전부 배제한 뒤에야 "폭 변환기 문제"라는 최종 가설에 비트스트림 재생성이라는 비용을 씀

---

## 10. 현재 상태 및 남은 작업

- [x] IP 패키징 및 블록디자인 구성
- [x] UART 미설정 문제 해결 (MIO 36/37 활성화)
- [x] Vitis 플랫폼 캐시 문제 우회 방법 확립 (파일 직접 대조/교체)
- [x] 리셋 극성 버그 수정 (`peripheral_reset`로 재배선)
- [x] `dcm_locked` 미연결 문제 수정 (`xlconstant` 추가)
- [x] 트렁크 삭제로 인한 연쇄 단선 복구
- [x] FSBL 링크 실패 수정 (`psu_init_gpl.c` 제거)
- [x] CSR 첫 쓰기에서 CPU 완전 hang — **근본 원인: PS-PL isolation + fabric reset 미해제 (JTAG 플로우), 앱 코드로 해결**
- [x] 실보드에서 레이어 1 완주 (`done=1`) 확인
- [x] 앱 메모리 위치 이동 (`lscript.ld` ORIGIN `0x0` → `0x1000_0000`)
- [x] `dram.txt`를 앱에 내장해 DDR에 로드 + readback 검증 (65536워드, 불일치 0)
- [x] **6레이어 전체 실보드 실행, 928/928 골든값 일치** (총 68.8ms)
- [ ] (성능) `axi4_master_dram.v`에 AXI4 버스트 전송 도입 — 현재 단일 워드 트랜잭션이라 실보드가 시뮬 대비 ~3.4× 느림
- [ ] (배포용) BOOT.BIN으로 SD 부팅 — 이 경우 FSBL이 isolation/reset을 알아서 처리하므로 앱의 수동 해제 코드와 중복 여부 확인
