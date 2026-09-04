# Cobalt CRM

<img width="2080" height="560" alt="cobalt_logo_minimal_dark" src="https://github.com/user-attachments/assets/222b38e3-3d1d-45a2-a843-209c526a9909" />

## Cobalt는 어떤 회사인가

Cobalt는 엘리베이터, HVAC, 발전기 같은 산업 설비를 파는 회사가 아니라, 그 설비가 멈추지 않고 계속 돌아가도록 관리해주는 서비스를 파는 가상의 회사입니다.

그래서 Cobalt의 일은 계약서에 도장을 찍는 순간 끝나지 않습니다. 계약 이후에도 기술자가 현장에 나가고, 부품을 쓰고, 작업을 완료하고, 청구서를 보내는 과정이 계속 이어집니다. 영업팀은 이 딜이 실행 가능한 딜인지(기술자를 몇 명이나 투입해야 하는지, 할인을 얼마나 해줄 수 있는지)를 판단해야 하고, 현장팀은 그 계약이 실제로 이행되는지를 매일 확인해야 합니다.

이 레포는 그 두 흐름, 영업 파이프라인과 현장 서비스 실행을 하나의 Salesforce 조직 안에서 이어보려고 만든 프로젝트입니다.

## 왜 만들었는가

Cobalt 같은 회사에서 CRM은 흔히 두 개로 쪼개져서 따로 돕니다. 영업은 Salesforce를, 현장은 별도의 필드 서비스 툴을 쓰는 식입니다. 그러다 보니 영업이 약속한 내용과 현장에서 실제로 벌어지는 일 사이에 항상 틈이 생깁니다.

이 프로젝트는 그 틈을 하나의 데이터 모델과 자동화로 메울 수 있는지를 직접 확인해보기 위해 만들었습니다. Opportunity가 Closed Won이 되는 순간 서비스 계약과 작업 지시가 자동으로 생기고, 작업이 끝나면 청구까지 이어지는 흐름을 실제로 동작하는 오브젝트, Apex, Flow로 구현해서 증명하려 했습니다.

## 영업 파이프라인 영역

Cobalt의 영업팀이 겪는 문제는 두 가지였습니다. 하나는 딜이 준비되지 않은 채로 다음 단계로 넘어가는 것이고, 다른 하나는 할인이 통제 없이 나가는 것입니다.

첫 번째 문제는 Opportunity의 단계 전환 자체에 조건을 걸어서 풀었습니다. Discovery 단계를 벗어나려면 MEDDIC 자격 검증 점수가 채워져 있어야 하고, Closed Lost 처리에는 사유가, Closed Won 처리에는 계약서 검토가 필수입니다. MEDDIC_Qualification_Screen_Flow가 그 점수를 입력받는 화면이고, 다섯 개의 Validation Rule이 각 단계의 게이트 역할을 합니다.

두 번째 문제는 할인 승인 프로세스로 풀었습니다. Proposal 단계에서 할인율이 15퍼센트를 넘으면 VP의 승인 없이는 그 단계로 들어갈 수 없습니다. Cobalt_Discount_Approval 승인 프로세스가 이 흐름을 처리하고, 승인이나 반려가 나면 이메일로 담당자에게 자동으로 알립니다.

그 앞단에서는 Lead_Scoring_and_Routing이 들어온 리드를 점수로 나눠 담당자에게 배분하고, Account에는 최근 12개월 매출과 오픈 파이프라인 합계가 롤업되어서 영업 담당자가 계정 단위로 상태를 바로 볼 수 있습니다. 큰 계약 전에는 Pilot__c로 소규모 시범 운영을 먼저 돌리는데, Pilot_AtRisk_Alert과 Pilot_EndDate_Reminder가 파일럿이 위험 상태이거나 종료일이 다가올 때 담당자에게 알려줍니다.

## 현장 서비스 실행 영역

Pilot이 통과하거나 계약이 성사되면 Service_Contract__c가 만들어집니다. 이 서비스 계약 안에서 실제 작업 단위인 Work_Order__c가 여러 건 생기고, 하나의 Work Order는 Technician__c(배정된 기술자), Part_Line__c(사용한 부품과 수량)와 연결됩니다. 그래서 한 번의 출동에 누가, 무엇을, 얼마나 썼는지가 그대로 남습니다.

Work Order가 새로 생기면 TechnicianAssignmentService와 WorkOrderAssignmentBatch가 조건에 맞는 기술자를 찾아 배정합니다. 배정이 안 된 건은 Dispatcher_Queue로 모이고, dispatcherBoard LWC에서 디스패처가 직접 배정할 수 있습니다. 작업 중에는 slaCountdown이 SLA 마감까지 남은 시간을 보여주고, WeatherRescheduleService가 날씨 때문에 일정을 조정해야 하는 경우를 처리합니다. 작업이 끝나면 fieldCompletion과 workPhotoGallery로 완료 처리와 현장 사진 업로드가 이루어집니다.

작업이 끝난 뒤에는 InvoiceGenerationService가 Invoice__c를 만들고 PaymentCalloutQueueable이 결제를 트리거합니다. 부품 재고가 재주문 기준 아래로 떨어지면 Part_Reorder__e 플랫폼 이벤트가 발행되고 ERPInventorySyncService가 이를 받아 처리합니다. 경로, 날씨, 재고, ERP, 결제, 이 다섯 개의 외부 시스템과 주고받은 요청과 응답은 전부 Integration_Log__c에 남아서, 나중에 무슨 일이 있었는지 추적할 수 있습니다.

## 주요 기능

- 리드 스코어링과 자동 배분

- MEDDIC 자격 검증 화면과 점수 기반 파이프라인 게이트

- 할인율 기준 VP 승인 프로세스

- 파일럿 관리와 위험 상태 알림, 유료 전환 추적

- Opportunity Closed Won 시 서비스 계약 자동 생성

- 기술자 배정 엔진과 디스패처 보드

- SLA 마감 추적과 날씨 기반 일정 재조정

- 부품 사용 내역 기록과 재고 재주문 연동

- 경로, 날씨, 재고, ERP, 결제 외부 API 연동과 호출 로그

- 작업 완료 처리와 현장 사진 업로드

- 청구서 생성과 결제 콜아웃

## 사용한 기술

- Apex (트리거, 서비스 클래스, Queueable, Batch, REST 리소스)

- Lightning Web Components

- Flow, Validation Rule, 승인 프로세스, Workflow Rule

- Platform Event

- Named Credential을 통한 외부 REST 연동

- Apex 단위 테스트와 Jest

## 폴더 구조

```
force-app/main/default/
  objects/          커스텀 오브젝트와 표준 오브젝트 확장 필드
  flows/            화면 흐름과 자동화 Flow
  approvalProcesses/ 할인 승인 프로세스
  triggers/         Apex 트리거
  classes/          Apex 서비스, 핸들러, 컨트롤러, 테스트 클래스
  lwc/              Lightning Web Components
  flexipages/       LWC를 배치한 Lightning 페이지
  layouts/, tabs/, applications/  화면 구성
  permissionsets/, profiles/, roles/  권한과 조직 구조
  namedCredentials/ 외부 API 연동 설정 (엔드포인트는 플레이스홀더로 대체되어 있습니다)
  dashboards/, reports/  영업 현황 리포트와 대시보드
scripts/            데모 데이터 시딩과 정리에 쓴 Apex, SOQL 스크립트
```

namedCredentials 안의 endpoint 값은 실제 서비스 주소가 아니라 개발 중 사용한 mock 엔드포인트였기 때문에, 레포에는 `https://TODO-REPLACE-WITH-YOUR-ENDPOINT.example.com`으로 남겨두었습니다. 이 조직을 실제로 배포해서 쓰려면 각자의 엔드포인트로 채워 넣어야 합니다.
