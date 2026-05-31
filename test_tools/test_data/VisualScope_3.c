//
// ********************************************************************************
//	File:			VisualScope.c
//	Project:		810A
//	Data:			22-12-2017
//	Author:			Ralap
//	Version: 		V1.0
//	Description:
// ********************************************************************************
//   Ver | dd-mmm-yyyy | Author| Description of changes
//  =====|=============|=======|===================================================
//  1.00 | 22-12-2017 | Ralap  | Original Release.
//  -----|-------------|-------|---------------------------------------------------
// ********************************************************************************
//

#include "App.h"


VS VScope = VS_DEFAULTS;

//================================================================================
// Declare functions
//================================================================================
Uint16 CrcCheck(Uint8 *Buf, Uint16 CRC_CNT);
void OnLineSendData(void);
INT16S VsData[4][VS_LEN];
INT16S VsData1[4][VS_LEN];

RX_VAR RxVar;
TX_VAR TxVar;
INT8U VisualScopeOld = 0;
INT16S VsTemp[4];

INT16S VsGpio1 = 0;
INT32S Alpha;
INT32S Beta;

INT32S Ds;
INT32S Qs;
INT32S MechFbkTempVs;
INT16S VsTemp11;
INT16U VsTemp22 = 0;
INT16U VsTxCnt  = 0;

INT16S TaTmp;
INT16S TbTmp;
INT16S TcTmp;

INT16U VSChoose = 0;
INT16U ZTestM2  = 0;
INT16U ZTest    = 0;
INT32U SumTmp   = 0;
static void Usart2RxIrqCallback(void);
static void Usart2ErrIrqCallback(void);
static void Usart2TxIrqCallback(void);
static void Usart2TxCmpltIrqCallback(void);

//================================================================================
// Function          :ChxValueTable()
// Description       :��ȡ��Ӧͨ��������
// Inputs            :
// Outputs           :
// UpdateRecord      :
//================================================================================
INT16U ChxValueTable(INT16U Addr)
{
    INT16U VsTemp = 0;
    INT16S Index;
    switch (Addr)
    {
    case 0:    // �趨�ٶ�
        VsTemp = MotorCtl.Out.IqRef;
        break;
    case 1:    // �ٶ�ָ��
        VsTemp = MotorCtl.Out.VelCmd;
        break;
    case 2:                              // �ٶȷ���
        VsTemp = MotorCtl.Out.VelFbk;    // CHX_SPD_FBK;
        break;
    case 3:    // ��������
        VsTemp = MotorCtl.Out.CurFbk * 10;
        break;
    case 4:    // �����е�Ƕ�
        VsTemp = MotorCtl.Out.MechTheta;
        break;
    case 5:    // �����Ƕ�
        VsTemp = MotorCtl.Out.ElecTheta;
        break;
    case 6:    // ������ͣ��Ƕ�
        VsTemp = MotorCtl.Out.ThetamUp;
        break;
    case 7:    // ������ͣ��Ƕ�
        VsTemp = Adc.VoltAc;
        break;
    case 8:    // ĸ�ߵ�ѹ
        VsTemp = Adc.VoltBus;
        break;
    case 9:    // 0x09// ̧ѹ��λ��ָ��
        VsTemp = M2MotorCtl.Int.PositionCmd;
        break;
    case 10:    // 0x0A// ̧ѹ���ٶ�ָ��
        VsTemp = M2MotorCtl.Int.M2VelCmd;
        break;
    case 11:    // 0x0B// ̧ѹ�ŵ���ָ��
        VsTemp = M2MotorCtl.Out.Res2;
        break;
    case 12:    // 0x0C// ̧ѹ�Ż�е�Ƕ�
        VsTemp = M2MotorCtl.Out.MechTheta * 360 >> 16;
        break;
    case 13:    // 0x0D// ̧ѹ�ŵ�Ƕ�
        VsTemp = M2MotorCtl.Out.ElecTheta;
        break;
    case 14:    // 0x0E// ̧ѹ���ٶȷ���
        VsTemp = M2MotorCtl.Out.VelFbk;
        break;
    case 15:    // 0x0F// ̧ѹ�ŵ�������
        VsTemp = M2MotorCtl.Out.CurFbk;
        break;
    case 16:    // 0x10
        VsTemp = Adc.Servo1CurA;
        break;

    case 17:    // 0x11
        VsTemp = Adc.Servo1CurB;
        break;

    case 18:    // 0x12
        VsTemp = Adc.Servo2CurA;
        break;

    case 19:    // 0x13
        VsTemp = Adc.Servo2CurB;
        break;

    case 20:    // 0x14
        VsTemp = OutPutIndex;
        break;

    case 21:    // 0x15
        VsTemp = DataIqRef[OutPutIndex];
        break;


    case 24:    // 0x18
        VsTemp = DataIdRef[OutPutIndex];
        break;

    case 25:    // 0x19
        VsTemp = DataIuFbk[OutPutIndex];
        break;

    case 26:    // 0x1A
        VsTemp = DataIvFbk[OutPutIndex];
        break;

    case 28:    // 0x1C
        VsTemp = DataIqFbk[OutPutIndex];
        break;

    case 29:    // 0x1D
        VsTemp = DataIdFbk[OutPutIndex];
        break;

    case 30:    // 0x1E
        VsTemp = DataVelFbk[OutPutIndex];
        break;

    case 31:    // 0x1F
        VsTemp = DataVelRef[OutPutIndex];
        break;

    case 32:    // 0x20
        VsTemp = M2DataIqRef[OutPutIndex];
        break;

    case 33:    // 0x21
        VsTemp = M2DataIdRef[OutPutIndex];
        break;

    case 34:    // 0x22
        VsTemp = M2DataIuFbk[OutPutIndex];
        break;

    case 35:    // 0x23
        VsTemp = M2DataIvFbk[OutPutIndex];
        break;

    case 36:    // 0x24
        VsTemp = M2DataIqFbk[OutPutIndex];
        break;

    case 37:    // 0x25
        VsTemp = M2DataIdFbk[OutPutIndex];
        break;

    case 38:    // 0x26
        VsTemp = M2DataVelFbk[OutPutIndex];
        break;

    case 39:    // 0x27
        VsTemp = M2DataVelRef[OutPutIndex];
        break;
    case 40:    // 0x28
        VsTemp = M2MotorCtl.Out.M2VelCmd;
        break;
    case 43:    // 0x2B
        VsTemp = M2MotorCtl.Out.IuFbk;
        break;

    case 44:    // 0x2C
        VsTemp = M2MotorCtl.Out.IqRef;
        break;

    case 45:    // 0x2D
        VsTemp = M2MotorCtl.Out.MechTheta;
        break;

    case 46:    // 0x2E
        VsTemp = M2MotorCtl.Out.IvFbk;
        break;

    case 47:    // 0x2F
        VsTemp = M2MotorCtl.Out.ElecTheta;
        break;

    case 48:    // 0x30
        VsTemp = M2MotorCtl.Out.VsCh1;
        break;


    case 49:    // 0x31
        VsTemp = M2MotorCtl.Out.IuFbk;
        break;

    case 50:    // 0x32
        VsTemp = M2MotorCtl.Out.IvFbk;
        break;

    case 51:    // 0x33
        VsTemp = M2MotorCtl.Out.VsCh2;
        break;

    case 52:    // 0x34
        VsTemp = M2MotorCtl.Out.IdRef;
        break;


    case 54:    // 0x36
        VsTemp = M2MotorCtl.Out.RunState * 100;
        break;


    case 55:    // 0x37
        VsTemp = M2MotorCtl.Out.IqRef;
        break;

    case 56:    // 0x38
        VsTemp = MotorCtl.Out.VsCh4;
        break;

    case 57:    // 0x39
        VsTemp = GyTYJControl.TYJState * 100;
        break;

    case 58:    // 0x3A
        VsTemp = M2_QEI_CNT_OUT;
        break;


    case 59:    // 0x3B
        VsTemp = M2_INDEX_PIN * 1000;
        break;

    case 60:    // 0x3C
        VsTemp = CUTTOTYJTIMEINVERSE;
        break;

    case 61:    // 0x3D
        VsTemp = CUTTOTYJTIMEALONG;
        break;

    case 62:    // 0x3E
        VsTemp = VsTemp11;
        break;

    case 63:                                                 // 0x3F
        VsTemp = HisFtData.CacheTmp[0][HisFtData.OutCnt];    // GyPieceNeedle.NeedleCount;
        break;

    case 64:    // 0x40
        VsTemp = -M2MotorCtl.Out.VsCh1;
        break;

    case 65:    // 0x41
        VsTemp = -M2MotorCtl.Out.VsCh2;
        break;

    case 66:    // 0x42
        VsTemp = M2MotorCtl.Out.VsCh3;
        break;

    case 67:    // 0x43
        VsTemp = -M2MotorCtl.Out.VsCh4;
        break;

    case 68:    // 0x44
        VsTemp = M2MotorCtl.Out.Res1 * 100;
        break;


    case 0x45:
        VsTemp = Parameter[RunCurrentKp];
        break;

    case 0x46:
        VsTemp = Parameter[RunCurrentKi];
        break;

    case 0x47:
        VsTemp = Parameter[RunSpdKp];
        break;

    case 0x48:
        VsTemp = Parameter[RunSpdKi];
        break;

    case 0x49:
        VsTemp = Parameter[CutAdjustCurrentKp];
        break;

    case 0x4A:
        VsTemp = Parameter[CutAdjustCurrentKi];
        break;

    case 0x4B:
        VsTemp = Parameter[CutAdjustSpdKp];
        break;

    case 0x4C:
        VsTemp = Parameter[CutAdjustSpdKi];
        break;

    case 0x4D:
        VsTemp = Parameter[PostionKp];
        break;

    case 0x4E:
        VsTemp = Parameter[StopCurrentKp];
        break;

    case 0x4F:
        VsTemp = Parameter[StopCurrentKi];
        break;

    case 0x50:
        VsTemp = Parameter[StopSpdKp];
        break;

    case 0x51:
        VsTemp = Parameter[StopSpdKi];
        break;

    case 0x52:
        VsTemp = Parameter[FindPosCurrent];
        break;

    case 0x53:
        VsTemp = Parameter[LimitCurrent];
        break;

    case 0x54:
        VsTemp = Parameter[ProtectCurrent];
        break;

    case 0x55:
        VsTemp = Parameter[InitPostion];
        break;

    case 0x56:
        VsTemp = Parameter[VelUpNeedle];
        break;


    case 0x57:    // 0x40
        VsTemp = MotorCtl.Out.VsCh1;
        break;

    case 0x58:    // 0x41
        VsTemp = MotorCtl.Out.VsCh2;
        break;

    case 0x59:    // 0x42
        VsTemp = MotorCtl.Out.VsCh3;
        break;

    case 0x5A:    // 0x43
        VsTemp = -MotorCtl.Out.VsCh4;
        break;

    case 0x5B:    // 0x43
        VsTemp = Adc.Pedal;
        break;

    case 0x5C:
        VsTemp = GySystemGuard.SystemErr;
        break;

    case 0x5D:
        VsTemp = M2MotorCtl.Int.AdcRes;
        break;

    case 0x5E:
        VsTemp = PORT_GetBit(PortC, Pin01);
        break;

    case 0x5F:
        VsTemp = MotorCtl.Int.VelCmd;
        break;

    case 0x60:
        VsTemp = QEI_CNT_OUT;
        break;

    case 0x61:
        VsTemp = INDEX_PIN * 100;
        break;

    case 0x62:
        VsTemp = MotorCtl.Out.McSysErr;
        break;

    case 0x63:
        VsTemp = MotorCtl.Out.MState * 100;
        break;

    case 0x499:    // ���Ϲؼ��������ߴ洢λ��
        VsTemp = HisFtData.NowStorePos;
        break;
    case 0x67:                   // ���Ϲؼ��������ߴ洢λ��
        VsTemp = EDFA_DETECT;    //
        break;

    case 0x68:                  // ���Ϲؼ��������ߴ洢λ��
        VsTemp = PedalFlag1;    //
        break;

    case 0x69:                            // ���Ϲؼ��������ߴ洢λ��
        VsTemp = GyModal.DCF5OPENFlag;    //
        break;

    case 0x6A:                            // ���Ϲؼ��������ߴ洢λ��
        VsTemp = GyModal.DCF4OPENFlag;    //
        break;

    case 0x70:                         // ���Ϲؼ��������ߴ洢λ��
        VsTemp = GyModal.DegDctErr;    // GyModal.DCF4OPENFlag;//
        break;

    case 0x71:                                     // �ٶ�ָ��
        VsTemp = GyAnalaysis.BackSecretProFlag;    // MotorCtl.Out.VelCmd;
        break;

    case 0x72:                          // �ٶȷ���
        VsTemp = GyModal.ModalState;    // MotorCtl.Out.VelFbk;//CHX_SPD_FBK;
        break;

    case 0x73:                                  // ��������
        VsTemp = GyAnalaysis.BackSecretFlag;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x74:                                  // ������������
        VsTemp = TimeCount.NetWorkNeedleCnt;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x75:                  // ��������̧ѹ�Ŵ���
        VsTemp = TYJTimeCnt;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x76:                         // ��������̧ѹ�Ŵ���
        VsTemp = TimeCount.SecCnt1;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x77:                        // ��������̧ѹ�Ŵ���
        VsTemp = TimeCount.SecCnt;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x78:                               // �������Ƽ��ߴ���
        VsTemp = TimeCount.NetWorkCutCnt;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x79:                                // ��̤״̬
        VsTemp = Gypedal.PedalState * 100;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x80:                              // �������Ƽ��ߴ���
        VsTemp = Gypedal.PedalStateFlag;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x81:                        // ��̤����ֵ
        VsTemp = Gypedal.PedalAdc;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x82:                                        // �ϵ����������־
        VsTemp = MotorCtl.Out.FindZeroFininshFlag;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x83:                                       // R308����ֵ
        VsTemp = Parameter[TYJSuspUpNeedleSelCh];    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x84:                                          // ͣ��λ
        VsTemp = GyAnalaysis.MotorInPut.UpNeedleSel;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x85:                                           // ��ͣ��Ƕ�
        VsTemp = GyAnalaysis.MotorOutPut.UpNeedleDeg;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x86:                         // ������λ����
        VsTemp = GyModal.DegDctErr;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x87:                           // ������λ��־
        VsTemp = GyModal.DegTextFlag;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x88:                           // ������λ��־
        VsTemp = MotorCtl.Int.VelCmd;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x89:                                          // BUS
        VsTemp = GyAnalaysis.MotorOutPut.BusVoltage;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x90:                              // BUS
        VsTemp = GyModal.ParaModifyFlag;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x91:               // BUS
        VsTemp = CALLNUM;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x92:                                    // BUS
        VsTemp = GyTrimControl.TrimActionFlag;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x93:                            // BUS
        VsTemp = NetTrimActionFlagOld;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x94:                               // BUS
        VsTemp = FucSixFlag.Bit.FrontCut;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x95:                                     // BUS
        VsTemp = Parameter[XLH_SERIAL_NUMBER1];    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x96:                                     // BUS
        VsTemp = Parameter[XLH_SERIAL_NUMBER2];    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x97:                                     // BUS
        VsTemp = Parameter[XLH_SERIAL_NUMBER3];    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x98:                    // BUS
        VsTemp = PedalPortOpt;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x99:                      // BUS
        VsTemp = XlhReciveState;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x9A:                             // ̧ѹ��״̬
        VsTemp = GyTYJControl.TYJState;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x9B:                                 // ̧ѹ��״̬
        VsTemp = GyTrimControl.TrimUpState;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x9C:                                   // ̧ѹ��״̬
        VsTemp = GyTrimControl.TrimDownState;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x9D:                  // ̧ѹ��״̬
        VsTemp = PedalFlag4;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x9E:                  // ̧ѹ��״̬
        VsTemp = PedalFlag3;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x100:                                // ̧ѹ��״̬
        VsTemp = GyAnalaysis.HGNeedleCount;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x101:                                   // ̧ѹ��״̬
        VsTemp = GyAnalaysis.FrtSecretProFlag;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x102:                                  // ̧ѹ��״̬
        VsTemp = GyAnalaysis.HGNeddleProFlag;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x103:                                       // ̧ѹ��״̬
        VsTemp = GyAnalaysis.FrtSecretNeedleCount;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x104:                              // ̧ѹ��״̬
        VsTemp = FucSixFlag.Bit.MotorRun;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x105:                         // ̧ѹ��״̬
        VsTemp = FucSixFlag.Allbits;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x106:                          // ̧ѹ��״̬
        VsTemp = MotorCtl.Out.MState;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x107:                                         // ̧ѹ��״̬
        VsTemp = GyAnalaysis.MotorOutPut.Motorstate;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x108:                  // ̧ѹ��״̬
        VsTemp = NetTYJState;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x109:                         // ̧ѹ��״̬
        VsTemp = GyModal.HGTrimFlag;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x10A:                        // ̧ѹ��״̬
        VsTemp = GyModal.PedalFlag;    // MotorCtl.Out.CurFbk*10;
        break;

    case 0x10B:                        // ̧ѹ��״̬
        VsTemp = GyModal.PedalFlag;    // MotorCtl.Out.CurFbk*10;
        break;
    default:
        // ����ʱ�ؼ��������
        // ����0:
        if ((Addr >= 0x500) && (Addr <= 0x515))
        {
            Index = Addr - 0x500;
            if (Index < 0)
            {
                Index = 0;
            }
            if (Index > 15)
            {
                Index = 15;
            }
            VsTemp = HisFtData.Cache0[Index][HisFtData.OutCnt];
        }
        // ����1:
        if ((Addr >= 0x600) && (Addr <= 0x615))
        {
            Index = Addr - 0x600;
            if (Index < 0)
            {
                Index = 0;
            }
            if (Index > 15)
            {
                Index = 15;
            }
            VsTemp = HisFtData.Cache1[Index][HisFtData.OutCnt];
        }
        // ����2:
        if ((Addr >= 0x700) && (Addr <= 0x715))
        {
            Index = Addr - 0x700;
            if (Index < 0)
            {
                Index = 0;
            }
            if (Index > 15)
            {
                Index = 15;
            }
            VsTemp = HisFtData.Cache2[Index][HisFtData.OutCnt];
        }
        break;
    }
    return VsTemp;
}
//================================================================================
// Function:			VisualScope()
// Description:		Visual Scope
// Inputs:			Void
// Update Record��   V1.00�� Deletion xxx processing
//================================================================================
void ViScope(void)
{
    INT16U CRC_Tmp;
    INT8U i;
    static INT16U RxClcCnt = 0;

    // ============================================================
    // ����Ȳ��ʱ�͵�ƽ����
    // ============================================================
    if (RxVar.RxCnt == 1)
    {
        RxClcCnt++;
        if (RxClcCnt > 100)
        {
            RxClcCnt    = 0;
            RxVar.RxCnt = 0;
        }
    }
    else
    {
        RxClcCnt = 0;
    }
    //  if(Parameter[VisualScopeModal] != VS_DIASBLE)
    //  {
    //      RxVar.RxFinishFlag = 1;
    //  }
    // RxVar.RxFinishFlag = 1;
    if (RxVar.RxFinishFlag == 0)
    {
        return;
    }
    else
    {
        // ���ܲ���
        /*
        TxVar.VsCh[0]  =
        MotorCtl.Out.VelCmd;////(int64_t)PiId.Fbk*2500>>24;//VoltLimit.VqOut*1000>>15;//(int64_t)PiVel.Ref*7500>>24;//BkStop.ThetamStop*360>>16;//IncEncoder.ThetamUp*3600>>16;//(int64_t)BkStop.VelCmd*7500>>24;//(int64_t)PiIq.Ref*2500>>24;//IncEncoder.ElecTheta;//(int64_t)PiId.Ref*10000>>24;
        TxVar.VsCh[1]  =
        MotorCtl.Out.VelFbk;////(int64_t)PiVel.Fbk*7500>>24;//BkStop.Thetam*3600>>16;;//(int64_t)PiIq.Fbk*2500>>24;//IncEncoder.MechTheta;//(int64_t)PiId.Fbk*10000>>24;
        TxVar.VsCh[2]  =
        MotorCtl.Out.BusVot;//VoltLimit.VdOut*1000>>15;////CtlSel.PrgStart*1000;//(int64_t)PiIq.Ref*2500>>24;//(int64_t)PiIq.Fbk*2500>>24;////BkStop.ThetamStopSum*360>>16;//SinCos.Angle;
        TxVar.VsCh[3]  = MotorCtl.Out.CurFbk;//(int64_t)PiVel.Ref*7500>>24;//(int64_t)PiIq.Fbk*2500>>24;//(int64_t)IncEncoder.ThetamUp *
        3600 >> 16;//(int64_t)IncEncoder.ElecTheta * ENCODER_PERIOD >> 16;//BkStop.Step*100;//(int64_t)Vel.MechFbk*7500 >>24;

        TxVar.VsCh[0]  =
        MotorCtl.Out.AcVot;////(int64_t)PiId.Fbk*2500>>24;//VoltLimit.VqOut*1000>>15;//(int64_t)PiVel.Ref*7500>>24;//BkStop.ThetamStop*360>>16;//IncEncoder.ThetamUp*3600>>16;//(int64_t)BkStop.VelCmd*7500>>24;//(int64_t)PiIq.Ref*2500>>24;//IncEncoder.ElecTheta;//(int64_t)PiId.Ref*10000>>24;
        TxVar.VsCh[1]  =
        MotorCtl.Out.MState;////(int64_t)PiVel.Fbk*7500>>24;//BkStop.Thetam*3600>>16;;//(int64_t)PiIq.Fbk*2500>>24;//IncEncoder.MechTheta;//(int64_t)PiId.Fbk*10000>>24;
        TxVar.VsCh[2]  =
        BRAKE_RIS_DET_IN*100;//VoltLimit.VdOut*1000>>15;////CtlSel.PrgStart*1000;//(int64_t)PiIq.Ref*2500>>24;//(int64_t)PiIq.Fbk*2500>>24;////BkStop.ThetamStopSum*360>>16;//SinCos.Angle;
        TxVar.VsCh[3]  = MotorCtl.Out.McSysErr*100;//
        */
        //        TxVar.VsCh[0]  =
        //        MotorCtl.Out.VelCmd;////(int64_t)PiId.Fbk*2500>>24;//VoltLimit.VqOut*1000>>15;//(int64_t)PiVel.Ref*7500>>24;//BkStop.ThetamStop*360>>16;//IncEncoder.ThetamUp*3600>>16;//(int64_t)BkStop.VelCmd*7500>>24;//(int64_t)PiIq.Ref*2500>>24;//IncEncoder.ElecTheta;//(int64_t)PiId.Ref*10000>>24;
        //        TxVar.VsCh[1]  =
        //        MotorCtl.Out.VelFbk;////(int64_t)PiVel.Fbk*7500>>24;//BkStop.Thetam*3600>>16;;//(int64_t)PiIq.Fbk*2500>>24;//IncEncoder.MechTheta;//(int64_t)PiId.Fbk*10000>>24;
        //        TxVar.VsCh[2]  =
        //        MotorCtl.Out.ThetamUp;//VoltLimit.VdOut*1000>>15;////CtlSel.PrgStart*1000;//(int64_t)PiIq.Ref*2500>>24;//(int64_t)PiIq.Fbk*2500>>24;////BkStop.ThetamStopSum*360>>16;//SinCos.Angle;
        //        TxVar.VsCh[3]  = MotorCtl.Out.Res1;;//
        //        TxVar.VsCh[0]  =
        //        MotorCtl.Out.McSysErr;////(int64_t)PiId.Fbk*2500>>24;//VoltLimit.VqOut*1000>>15;//(int64_t)PiVel.Ref*7500>>24;//BkStop.ThetamStop*360>>16;//IncEncoder.ThetamUp*3600>>16;//(int64_t)BkStop.VelCmd*7500>>24;//(int64_t)PiIq.Ref*2500>>24;//IncEncoder.ElecTheta;//(int64_t)PiId.Ref*10000>>24;
        //        TxVar.VsCh[1]  =
        //        MotorCtl.Out.VelFbk;////(int64_t)PiVel.Fbk*7500>>24;//BkStop.Thetam*3600>>16;;//(int64_t)PiIq.Fbk*2500>>24;//IncEncoder.MechTheta;//(int64_t)PiId.Fbk*10000>>24;
        //        TxVar.VsCh[2]  =
        //        MotorCtl.Out.CurFbk*10;//VoltLimit.VdOut*1000>>15;////CtlSel.PrgStart*1000;//(int64_t)PiIq.Ref*2500>>24;//(int64_t)PiIq.Fbk*2500>>24;////BkStop.ThetamStopSum*360>>16;//SinCos.Angle;
        //        TxVar.VsCh[3]  = MotorCtl.Out.BusVot*10;
        // TxVar.VsCh[0]  = FT_DETECT*100;//Parameter[ThinThickModalEn]
        // ;//LackPhaseValue;//MotorCtl.Out.VsCh1;//GyCommunicationDeal.Temp[6]; //
        // �˲���////(int64_t)PiId.Fbk*2500>>24;//VoltLimit.VqOut*1000>>15;//(int64_t)PiVel.Ref*7500>>24;//BkStop.ThetamStop*360>>16;//IncEncoder.ThetamUp*3600>>16;//(int64_t)BkStop.VelCmd*7500>>24;//(int64_t)PiIq.Ref*2500>>24;//IncEncoder.ElecTheta;//(int64_t)PiId.Ref*10000>>24;
        // TxVar.VsCh[1]  = Parameter[ThickDealModal] *200;//ENC_B*100;//GySystemGuard.SystemErr;//GyCommunicationDeal.Temp[2]; //
        // ���������PedalState*100;////(int64_t)PiVel.Fbk*7500>>24;//BkStop.Thetam*3600>>16;;//(int64_t)PiIq.Fbk*2500>>24;//IncEncoder.MechTheta;//(int64_t)PiId.Fbk*10000>>24;
        // TxVar.VsCh[2]  = GyModal.FabricFinsh *200;//Adc.Iu;//ENC_I*100;//
        // ��ֵ��//SystemErr;//VoltLimit.VdOut*1000>>15;////CtlSel.PrgStart*1000;//(int64_t)PiIq.Ref*2500>>24;//(int64_t)PiIq.Fbk*2500>>24;////BkStop.ThetamStopSum*360>>16;//SinCos.Angle;
        // TxVar.VsCh[3]  = abs((INT16S)GyAnalaysis.MotorOutPut.UpNeedleDeg -180);//Adc.Iv;
        // //VsTemp11;//MotorCtl.Out.ThetamUp;//Adc.Res;//GyAnalaysis.MotorOutPut.SoftWareVer;//Gypedal.PedalAdc;// ԭʼ//parameter[]*100
        // TxVar.VsCh[0]  =
        // Gypedal.AdcPedal;//M2MotorCtl.Out.VelFbk;//TrimAfterTYJFlag*100;//M2MotorCtl.Out.VsCh1;//GyTrimControl.TrimDownState*10;//SpdLoopGain;//PosDirInput*10;//CUTTOTYJTIMEALONG;//GyTrimControl.TrimDownState;//VsTemp15;//KeepCnt;//MotorCtl.Out.VsCh1;//MotorCtl.Out.VsCh1;//MotorCtl.Out.VelCmd;////(int64_t)PiId.Fbk*2500>>24;//VoltLimit.VqOut*1000>>15;//(int64_t)PiVel.Ref*7500>>24;//BkStop.ThetamStop*360>>16;//IncEncoder.ThetamUp*3600>>16;//(int64_t)BkStop.VelCmd*7500>>24;//(int64_t)PiIq.Ref*2500>>24;//IncEncoder.ElecTheta;//(int64_t)PiId.Ref*10000>>24;
        // TxVar.VsCh[1]  = MotorCtl.Out.VsCh4;//Gypedal.PedalSpeedOut;//GyTrimControl.TrimDownState*100;//GyTYJControl.TYJState
        // *10;//SpdLoopITime;//PosCmdInput;//CUTTOTYJTIMEINVERSE;//GyTYJControl.TYJState;//MotorCtl.Out.VsCh2;;//PosDirInput*100;//MotorCtl.Out.VsCh2;//MotorCtl.Out.VelFbk;//PosDirInput*100;//MotorCtl.Out.VelFbk;////(int64_t)PiVel.Fbk*7500>>24;//BkStop.Thetam*3600>>16;;//(int64_t)PiIq.Fbk*2500>>24;//IncEncoder.MechTheta;//(int64_t)PiId.Fbk*10000>>24;
        // TxVar.VsCh[2]  =
        // MotorCtl.Out.VelFbk;//M2MotorCtl.Out.VsCh3;//GyPieceNeedle.NeedleNotStopFlag*100;//Gypedal.PedalState*10;//PosCmdInputRef;//CutAngelRef;//CUTTIME;//PosDirInput;//SDO2_R_MC_RSV1;//MotorCtl.Out.VsCh3;;//PosCmdInput;//MotorCtl.Out.VsCh3;//GyTrimControl.TrimDownState*10;//MotorCtl.Out.ThetamUp;//VoltLimit.VdOut*1000>>15;////CtlSel.PrgStart*1000;//(int64_t)PiIq.Ref*2500>>24;//(int64_t)PiIq.Fbk*2500>>24;////BkStop.ThetamStopSum*360>>16;//SinCos.Angle;
        // TxVar.VsCh[3]  =
        // MotorCtl.Out.MechTheta;//M2MotorCtl.Out.VsCh4;//M2MotorCtl.Int.PositionCmd;//PDO2_R_DATE;//MotorCtl.Out.VsCh4;//PosCmdInput;//Gypedal.PedalState*10;//MotorCtl.Out.Res1;//
        /*�Ӽ������ܲ��Զ�
        TxVar.VsCh[0]  = Gypedal.AdcPedal;//M2MotorCtl.Out.MechTheta;//Gypedal.AdcPedal;//M2MotorCtl.Out.VsCh1;
        TxVar.VsCh[1]  = MotorCtl.Out.VsCh4;//MotorCtl.Out.VsCh4;//��������//MotorCtl.Out.VsCh3;��е�Ƕ�
        TxVar.VsCh[2]  = MotorCtl.Out.VelFbk;;//M2MotorCtl.Out.MechTheta;//M2MotorCtl.Out.VsCh3;
        TxVar.VsCh[3]  = MotorCtl.Out.MechTheta;//MotorCtl.Out.MechTheta;//M2MotorCtl.Out.VsCh4;
        */
        /*
        TxVar.VsCh[0]  = GyTYJControl.TYJState*100;
        TxVar.VsCh[1]  = GyTrimControl.TrimDownState*100;
        TxVar.VsCh[2]  = GyModal.ModalState*100;//M2MotorCtl.Int.M2VelCmd;
        TxVar.VsCh[3]  = VsTemp22;//M2MotorCtl.Int.PositionCmd;
        */
        /*
        //���Լ���̧ѹ������
        TxVar.VsCh[0]  = M2MotorCtl.Int.PositionCmd;
        TxVar.VsCh[1]  = M2MotorCtl.Out.VsCh3;
        TxVar.VsCh[2]  = M2MotorCtl.Int.M2VelCmd;
        TxVar.VsCh[3]  = M2MotorCtl.Out.VelFbk;
        */
        /*
         //���ߺ�̧ѹ��ʱ��
         TxVar.VsCh[0]  = Gypedal.PedalState*100;
         TxVar.VsCh[1]  = GyTYJControl.TYJState*100;
         TxVar.VsCh[2]  = GyTrimControl.TrimDownState*100;
         TxVar.VsCh[3]  = M2MotorCtl.Out.MechTheta;
         */
        /*
            //���̵��ڳ������
            TxVar.VsCh[0]  = M2MotorCtl.Out.VsCh1;//M2MotorCtl.Out.Res2;//
            TxVar.VsCh[1]  = M2MotorCtl.Out.VsCh2;//M2MotorCtl.Out.VsCh3;
            TxVar.VsCh[2]  = M2MotorCtl.Out.VsCh3;//M2MotorCtl.Int.M2VelCmd;
            TxVar.VsCh[3]  = (M2MotorCtl.Out.MechTheta<<16)/360;//�ٶ�ָ��//M2MotorCtl.Int.PositionCmd;
        */
        /*
         //���̵��ڲ���
         TxVar.VsCh[0]  = M2MotorCtl.Int.PositionCmd;//M2MotorCtl.Out.Res2;//
         TxVar.VsCh[1]  = M2MotorCtl.Out.MechTheta;//M2MotorCtl.Out.VsCh3;
         TxVar.VsCh[2]  = M2MotorCtl.Out.VsCh3;//M2MotorCtl.Int.M2VelCmd;
         TxVar.VsCh[3]  = M2MotorCtl.Out.VsCh1;//�ٶ�ָ��//M2MotorCtl.Int.PositionCmd;
        */
        // ------------------------------------------------------------
        // ������Ϲؼ�����
        // ------------------------------------------------------------
        HisFtData.OutCnt++;
        if (HisFtData.OutCnt >= HIS_DATA_LEN)
        {
            HisFtData.OutCnt = 0;
        }

        OutPutIndex++;
        if (OutPutIndex >= 128)
        {
            OutPutIndex = 0;
        }
        if (Parameter[VisualScopeModal] == 1)
        {
            //    TxVar.VsCh[0] = ChxValueTable(4);
            //    TxVar.VsCh[1] = ChxValueTable(5);
            //    TxVar.VsCh[2] = ChxValueTable( 0x60);
            //    TxVar.VsCh[3] = ChxValueTable( RxVar.Addr4);

            TxVar.VsCh[0] = ChxValueTable(RxVar.Addr1);
            TxVar.VsCh[1] = ChxValueTable(RxVar.Addr2);
            TxVar.VsCh[2] = ChxValueTable(RxVar.Addr3);
            TxVar.VsCh[3] = ChxValueTable(RxVar.Addr4);
        }
        else if (Parameter[VisualScopeModal] == 2)
        {
            //    TxVar.VsCh[0] = 1;//ChxValueTable( RxVar.Addr5);
            //    TxVar.VsCh[1] = 2;//ChxValueTable( RxVar.Addr6);
            //    TxVar.VsCh[2] = 3;//ChxValueTable( RxVar.Addr7);
            //    TxVar.VsCh[3] = 4;//ChxValueTable( RxVar.Addr8);
            //    TxVar.VsCh[4] = 5;//ChxValueTable( RxVar.Addr9);
            //    TxVar.VsCh[5] = 6;//ChxValueTable( RxVar.Addr10);
            //    TxVar.VsCh[6] = 7;//ChxValueTable( RxVar.Addr11);
            //    TxVar.VsCh[7] = 8;//ChxValueTable( RxVar.Addr12);
            //
            TxVar.VsCh[0] = ChxValueTable(RxVar.Addr5);
            TxVar.VsCh[1] = ChxValueTable(RxVar.Addr6);
            TxVar.VsCh[2] = ChxValueTable(RxVar.Addr7);
            TxVar.VsCh[3] = ChxValueTable(RxVar.Addr8);
            TxVar.VsCh[4] = ChxValueTable(RxVar.Addr9);
            TxVar.VsCh[5] = ChxValueTable(RxVar.Addr10);
            TxVar.VsCh[6] = ChxValueTable(RxVar.Addr11);
            TxVar.VsCh[7] = ChxValueTable(RxVar.Addr12);
        }
        //    TxVar.VsCh[0] = ChxValueTable( 0x3B);
        //    TxVar.VsCh[1] = ChxValueTable( 0x3A);
        //    TxVar.VsCh[2] = ChxValueTable( 0x43);
        //    TxVar.VsCh[3] = ChxValueTable( 0x34);
    }
    if (VSChoose == VS_4)
    {
        for (i = 0; i < 4; i++)
        {
            TxVar.TxBuf[2 * i]     = TxVar.VsCh[i] & 0x00FF;           // L8bit;
            TxVar.TxBuf[2 * i + 1] = (TxVar.VsCh[i] >> 8) & 0x00FF;    // H8bit
        }
        // CRC У�����
        CRC_Tmp        = CrcCheck(TxVar.TxBuf, 8);
        TxVar.TxBuf[8] = CRC_Tmp & 0xff;
        TxVar.TxBuf[9] = CRC_Tmp >> 8;

        VsTxCnt = 0;
    }
    else if (VSChoose == VS_8)
    {
        for (i = 0; i < 8; i++)
        {
            TxVar.TxBuf1[2 * i]     = TxVar.VsCh[i] & 0x00FF;           // L8bit;
            TxVar.TxBuf1[2 * i + 1] = (TxVar.VsCh[i] >> 8) & 0x00FF;    // H8bit
        }
        // CRC У�����
        CRC_Tmp          = CrcCheck(TxVar.TxBuf1, 16);
        TxVar.TxBuf1[16] = CRC_Tmp & 0xff;
        TxVar.TxBuf1[17] = CRC_Tmp >> 8;

        VsTxCnt = 0;
    }
    USART_FuncCmd(USART2_CH, UsartTxAndTxEmptyInt, Enable);    // Start Tx data.
                                                               // FIFO����10Bytes����
                                                               /*
                                                               for(i=0; i<TX_COUNT_MAX; i++)
                                                               {
                                                                 while(USART2_CH->SR_f.TXE==0);     //��λ���ݼĴ�����Ϊ��
                                                                 USART_SendData(USART2_CH,TxVar.TxBuf[i]);
                                                                 while(USART2_CH->SR_f.TC==0);    //����δ�������
                                                               }
                                                               */
}
//================================================================================
// Function:			VSUart2Init()
// Description:
// Inputs:			Void
// Outputs:			Void
// Update Record��   V1.00�� Deletion xxx processing
//================================================================================
void VSUart2Init(void)    // PC10--TX   PC11--RX
{
    en_result_t enRet = Ok;
    stc_irq_regi_conf_t stcIrqRegiCfg;
    const stc_usart_uart_init_t stcInitCfg = {
        UsartIntClkCkNoOutput,    // select internal clock source and don't output clock.
        UsartClkDiv_16,           // PCLK/16
        UsartDataBits8,           // 8λ
        UsartDataLsbFirst,        // LSB first
        UsartOneStopBit,          // 1��ֹͣλ
        UsartParityNone,          // ����żУ��
        UsartSamleBit8,           // ������ģʽ�趨����һλ���ݴ����ڼ�Ļ���ʱ����
        UsartStartBitFallEdge,    // ��ʼλ���ģʽ���½���
        UsartRtsEnable,           // RTS����ʹ��  P667
    };

    /* Enable peripheral clock */
    PWC_Fcg1PeriphClockCmd(PWC_FCG1_PERIPH_USART2, Enable);

    // ------------------------------------------------------------
    // UART2������+����ʾ������
    // ------------------------------------------------------------
    /* Initialize USART IO */
    PORT_SetFunc(USART2_RX_PORT, USART2_RX_PIN, USART2_RX_FUNC, Disable);    // Disable:˫�ܱ߹���ʧ�� P265
    PORT_SetFunc(USART2_TX_PORT, USART2_TX_PIN, USART2_TX_FUNC, Disable);
    enRet = USART_UART_Init(USART2_CH, &stcInitCfg);
    if (enRet != Ok)
    {
        while (1)
        {
            ;
        }
    }

    /* Set baudrate */
    if (Parameter[VisualScopeModal] == VS_4)
    {
        enRet    = USART_SetBaudrate(USART2_CH, USART2_BAUD_1MS);    // 115200bps
        VSChoose = VS_4;
    }
    else if (Parameter[VisualScopeModal] == VS_8)
    {
        enRet    = USART_SetBaudrate(USART2_CH, USART2_BAUD_8);    // 230400bps
        VSChoose = VS_8;
    }
    if (enRet != Ok)
    {
        while (1)
        {
            ;
        }
    }
    // USART_SetBaudrate(USART2_CH, USART2_BAUD_1MS);
    /* Set USART RX IRQ */
    stcIrqRegiCfg.enIRQn      = VECT_NUM_USART2_RX;      // �ж����11
    stcIrqRegiCfg.pfnCallback = &Usart2RxIrqCallback;    // �жϺ���
    stcIrqRegiCfg.enIntSrc    = USART2_RI_NUM;           // 279u  �ж�����:����2�����ж�
    enIrqRegistration(&stcIrqRegiCfg);
    NVIC_SetPriority(stcIrqRegiCfg.enIRQn, DDL_IRQ_PRIORITY_DEFAULT);    // 15  �ж����ȼ����
    NVIC_ClearPendingIRQ(stcIrqRegiCfg.enIRQn);
    NVIC_EnableIRQ(stcIrqRegiCfg.enIRQn);

    /* Set USART RX error IRQ */
    stcIrqRegiCfg.enIRQn      = VECT_NUM_USART2_RX_ERR;    // �ж����12
    stcIrqRegiCfg.pfnCallback = &Usart2ErrIrqCallback;
    stcIrqRegiCfg.enIntSrc    = USART2_EI_NUM;    // 283u �ж����ͣ�����2���մ����ж�
    enIrqRegistration(&stcIrqRegiCfg);
    NVIC_SetPriority(stcIrqRegiCfg.enIRQn, DDL_IRQ_PRIORITY_DEFAULT);    // 15  �ж����ȼ����
    NVIC_ClearPendingIRQ(stcIrqRegiCfg.enIRQn);
    NVIC_EnableIRQ(stcIrqRegiCfg.enIRQn);

    /* Set USART TX IRQ */
    stcIrqRegiCfg.enIRQn      = VECT_NUM_USART2_TX;    // �ж����13
    stcIrqRegiCfg.pfnCallback = &Usart2TxIrqCallback;
    stcIrqRegiCfg.enIntSrc    = USART2_TI_NUM;
    enIrqRegistration(&stcIrqRegiCfg);
    NVIC_SetPriority(stcIrqRegiCfg.enIRQn, DDL_IRQ_PRIORITY_DEFAULT);
    NVIC_ClearPendingIRQ(stcIrqRegiCfg.enIRQn);
    NVIC_EnableIRQ(stcIrqRegiCfg.enIRQn);

    /* Set USART TX complete IRQ */
    stcIrqRegiCfg.enIRQn      = VECT_NUM_USART2_TXCOMP;    // �ж����14
    stcIrqRegiCfg.pfnCallback = &Usart2TxCmpltIrqCallback;
    stcIrqRegiCfg.enIntSrc    = USART2_TCI_NUM;
    enIrqRegistration(&stcIrqRegiCfg);
    NVIC_SetPriority(stcIrqRegiCfg.enIRQn, DDL_IRQ_PRIORITY_DEFAULT);
    NVIC_ClearPendingIRQ(stcIrqRegiCfg.enIRQn);
    NVIC_EnableIRQ(stcIrqRegiCfg.enIRQn);


    /*Enable RX && RX interupt function*/
    // USART_FuncCmd(USART2_CH, UsartTx, Enable);
    USART_FuncCmd(USART2_CH, UsartRx, Enable);
    USART_FuncCmd(USART2_CH, UsartRxInt, Enable);    // RI��ERI�жϷ���  P702

    RxVar.RxCnt        = 0;
    RxVar.RxFinishFlag = 0;
}

//================================================================================
// Function:			CrcCheck()
// Description:		Crc
// Inputs:			Void
// Update Record��   V1.00�� Deletion xxx processing
//================================================================================
Uint16 CrcCheck(Uint8 *Buf, Uint16 CRC_CNT)
{
    Uint16 CRC_Temp;
    Uint16 i, j;
    CRC_Temp = 0xffff;

    for (i = 0; i < CRC_CNT; i++)
    {
        CRC_Temp ^= (Uint16)Buf[i];
        for (j = 0; j < 8; j++)
        {
            if (CRC_Temp & 0x01)
                CRC_Temp = (CRC_Temp >> 1) ^ 0xa001;
            else
                CRC_Temp = CRC_Temp >> 1;
        }
    }
    return (CRC_Temp);
}

/**
 *******************************************************************************
 ** \brief USART TX irq callback function.
 **
 ** \param [in] None
 **
 ** \retval None
 ** δ�������
 ******************************************************************************/
static void Usart2TxIrqCallback(void)
{
    if (VSChoose == VS_4)
    {
        if (VsTxCnt < TX_COUNT_MAX)
        {
            USART_SendData(USART2_CH, TxVar.TxBuf[VsTxCnt]);
        }
        else
        {
            VsTxCnt = 0;
            USART_FuncCmd(USART2_CH, UsartTxEmptyInt, Disable);
            USART_FuncCmd(USART2_CH, UsartTxCmpltInt, Enable);
        }
        VsTxCnt++;
    }
    else if (VSChoose == VS_8)
    {
        if (VsTxCnt < TX_COUNT_MAX1)
        {
            USART_SendData(USART2_CH, TxVar.TxBuf1[VsTxCnt]);
        }
        else
        {
            VsTxCnt = 0;
            USART_FuncCmd(USART2_CH, UsartTxEmptyInt, Disable);
            USART_FuncCmd(USART2_CH, UsartTxCmpltInt, Enable);
        }
        VsTxCnt++;
    }
}

/**
 *******************************************************************************
 ** \brief USART TX complete irq callback function.
 **
 ** \param [in] None
 **
 ** \retval None
 **
 ******************************************************************************/
static void Usart2TxCmpltIrqCallback(void)
{
    USART_FuncCmd(USART2_CH, UsartTxCmpltInt, Disable);
    USART_FuncCmd(USART2_CH, UsartTx, Disable);
}

// ================================================================================
// UART2
// ================================================================================
/**
 *******************************************************************************
 ** \brief USART RX irq callback function.
 **
 ** \param [in] None
 **
 ** \retval None
 **
 ******************************************************************************/
static void Usart2RxIrqCallback(void)
{
    if (VSChoose == VS_4)
    {
        uint16_t CRC_Tmp;
        uint16_t CRC_RX;
        RxVar.RxBuf[RxVar.RxCnt] = USART_RecData(USART2_CH);
        RxVar.RxCnt++;
        // TS_RX_IRQHandler(m_u16RxData);
        if (RxVar.RxCnt == RX_COUNT_MAX)    // 18
        {
            CRC_Tmp = CrcCheck(RxVar.RxBuf, 16);    // CRC Calculation
            CRC_RX  = ((Uint16)RxVar.RxBuf[RX_COUNT_MAX - 1] << 8) + RxVar.RxBuf[RX_COUNT_MAX - 2];
            if (CRC_Tmp == CRC_RX)
            {
                RxVar.RxFinishFlag = 1;
                RxVar.Addr1        = (Uint16)((RxVar.RxBuf[1] << 8) | RxVar.RxBuf[0]);
                RxVar.Addr2        = (Uint16)((RxVar.RxBuf[5] << 8) | RxVar.RxBuf[4]);
                RxVar.Addr3        = (Uint16)((RxVar.RxBuf[9] << 8) | RxVar.RxBuf[8]);
                RxVar.Addr4        = (Uint16)((RxVar.RxBuf[13] << 8) | RxVar.RxBuf[12]);
            }
            RxVar.RxCnt = 0;
        }
    }
    else if (VSChoose == VS_8)
    {
        uint16_t CRC_Tmp;
        uint16_t CRC_RX;
        RxVar.RxBuf1[RxVar.RxCnt] = USART_RecData(USART2_CH);
        RxVar.RxCnt++;
        // TS_RX_IRQHandler(m_u16RxData);
        if (RxVar.RxCnt == RX_COUNT_MAX1)    // 18
        {
            CRC_Tmp = CrcCheck(RxVar.RxBuf1, 32);    // CRC Calculation
            CRC_RX  = ((Uint16)RxVar.RxBuf1[RX_COUNT_MAX1 - 1] << 8) + RxVar.RxBuf1[RX_COUNT_MAX1 - 2];
            if (CRC_Tmp == CRC_RX)
            {
                RxVar.RxFinishFlag = 1;
                RxVar.Addr5        = (Uint16)((RxVar.RxBuf1[1] << 8) | RxVar.RxBuf1[0]);
                RxVar.Addr6        = (Uint16)((RxVar.RxBuf1[5] << 8) | RxVar.RxBuf1[4]);
                RxVar.Addr7        = (Uint16)((RxVar.RxBuf1[9] << 8) | RxVar.RxBuf1[8]);
                RxVar.Addr8        = (Uint16)((RxVar.RxBuf1[13] << 8) | RxVar.RxBuf1[12]);
                RxVar.Addr9        = (Uint16)((RxVar.RxBuf1[17] << 8) | RxVar.RxBuf1[16]);
                RxVar.Addr10       = (Uint16)((RxVar.RxBuf1[21] << 8) | RxVar.RxBuf1[20]);
                RxVar.Addr11       = (Uint16)((RxVar.RxBuf1[25] << 8) | RxVar.RxBuf1[24]);
                RxVar.Addr12       = (Uint16)((RxVar.RxBuf1[29] << 8) | RxVar.RxBuf1[28]);
            }
            RxVar.RxCnt = 0;
        }
    }
}

/**
 *******************************************************************************
 ** \brief USART RX error irq callback function.
 **
 ** \param [in] None
 **
 ** \retval None
 **
 ******************************************************************************/
static void Usart2ErrIrqCallback(void)
{
    if (Set == USART_GetStatus(USART2_CH, UsartFrameErr))    // ֡����
    {
        USART_ClearStatus(USART2_CH, UsartFrameErr);
    }
    else if (Set == USART_GetStatus(USART2_CH, UsartParityErr))    // ��żУ�����
    {
        USART_ClearStatus(USART2_CH, UsartParityErr);
    }
    else if (Set == USART_GetStatus(USART2_CH, UsartOverrunErr))    // �������
    {
        USART_ClearStatus(USART2_CH, UsartOverrunErr);
    }
    else
    {
    }
}
