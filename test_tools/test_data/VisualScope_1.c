// ********************************************************************************
//	File:			VisualScope.c
//	Project:
//	Data:			16-06-2021
//	Author:			ZT
//	Version: 		V1.0
//	Description:
// ********************************************************************************
//   Ver | dd-mmm-yyyy | Author| Description of changes
//  =====|=============|=======|===================================================
//  1.00 | 16-06-2021  | ZT     | Original Release.
//  -----|-------------|-------|---------------------------------------------------
// ********************************************************************************


#include "App.h"
#include "stdarg.h"
#include "string.h"
#include "stdio.h"
//==============================================================================
// Declare functions
//==============================================================================
void ChxValueTable(void);

VS_RX_VAR VsRxVar;
VS_TX_VAR VsTxVar;
static void VsUsartRxIrqCallback(void);
static void VsUsartTxIrqCallback(void);
void VsUsartTCIrqCallback(void);
void VsUsartErrIrqCallback(void);
int16_t VsTemp[4];
int16_t TestFlag1 = 0;
int16_t TestFlag2 = 0;
int16_t TestFlag3 = 0;
int16_t TestFlag4 = 40;
int16_t TestFlag5 = 50;
int16_t TestFlag6 = 60;
int16_t TestFlag7 = 70;
int16_t TestFlag8 = 80;
int16_t TestFlag9 = 90;
int32_t TestCnt   = 0;
uint16_t TestFlag = 0;
uint16_t ErrFF    = 0;
uint16_t Err00    = 0;
extern uint32_t UseTime1Us;
extern SYNC Sync;

//================================================================================
// Function:			Hc32f46xUsartConfig()
// Description:
// Inputs:			Void
// Outputs:			Void
// Update Record：   V1.00： Deletion xxx processing
//================================================================================
void VsUsartInit(uint32_t bdr)
{
    stc_usart_uart_init_t stcUartInit;
    stc_irq_signin_config_t stcIrqRegiCfg;

    /* Enable peripheral clock */
    VSUSART_FCG_ENABLE();
    /* Initialize USART IO */
    GPIO_SetFunc(VISCOPE_RX_PORT, VISCOPE_RX_PIN, VISCOPE_RX_FUNC);
    GPIO_SetFunc(VISCOPE_TX_PORT, VISCOPE_TX_PIN, VISCOPE_TX_FUNC);
    (void)USART_UART_StructInit(&stcUartInit);
    stcUartInit.u32ClockDiv      = USART_CLK_DIV64;
    stcUartInit.u32Baudrate      = bdr;
    stcUartInit.u32OverSampleBit = USART_OVER_SAMPLE_8BIT;
    if (LL_OK != USART_UART_Init(VSUSARTX, &stcUartInit, NULL))
    {
        for (;;)
        {
        }
    }
    /* Set USART RX IRQ */
    stcIrqRegiCfg.enIRQn      = VECT_NUM_VSUSART_RX;
    stcIrqRegiCfg.pfnCallback = &VsUsartRxIrqCallback;
    stcIrqRegiCfg.enIntSrc    = VSUSART_RI_NUM;
    (void)INTC_IrqSignIn(&stcIrqRegiCfg);
    NVIC_SetPriority(stcIrqRegiCfg.enIRQn, DDL_IRQ_PRIO_15);
    NVIC_ClearPendingIRQ(stcIrqRegiCfg.enIRQn);
    NVIC_EnableIRQ(stcIrqRegiCfg.enIRQn);

    /* Set USART TX IRQ */
    stcIrqRegiCfg.enIRQn      = VECT_NUM_VSUSART_TX;
    stcIrqRegiCfg.pfnCallback = &VsUsartTxIrqCallback;
    stcIrqRegiCfg.enIntSrc    = VSUSART_TI_NUM;    // 发送寄存器空中断
    (void)INTC_IrqSignIn(&stcIrqRegiCfg);
    NVIC_SetPriority(stcIrqRegiCfg.enIRQn, DDL_IRQ_PRIO_15);
    NVIC_ClearPendingIRQ(stcIrqRegiCfg.enIRQn);
    NVIC_EnableIRQ(stcIrqRegiCfg.enIRQn);

    /* Set USART TC IRQ */
    stcIrqRegiCfg.enIRQn      = VECT_NUM_VSUSART_TC;
    stcIrqRegiCfg.pfnCallback = &VsUsartTCIrqCallback;
    stcIrqRegiCfg.enIntSrc    = VSUSART_TC_NUM;    // 发送寄存器空中断
    (void)INTC_IrqSignIn(&stcIrqRegiCfg);
    NVIC_SetPriority(stcIrqRegiCfg.enIRQn, DDL_IRQ_PRIO_09);    // DDL_IRQ_PRIORITY_15);
    NVIC_ClearPendingIRQ(stcIrqRegiCfg.enIRQn);
    NVIC_EnableIRQ(stcIrqRegiCfg.enIRQn);

    stcIrqRegiCfg.enIRQn      = VECT_NUM_VSUSART_RXERR;
    stcIrqRegiCfg.pfnCallback = &VsUsartErrIrqCallback;
    stcIrqRegiCfg.enIntSrc    = VSUSART_EI_NUM;
    (void)INTC_IrqSignIn(&stcIrqRegiCfg);
    NVIC_SetPriority(stcIrqRegiCfg.enIRQn, DDL_IRQ_PRIO_09);
    NVIC_ClearPendingIRQ(stcIrqRegiCfg.enIRQn);
    NVIC_EnableIRQ(stcIrqRegiCfg.enIRQn);


    // USART_FuncCmd(VSUSARTX, UsartNoiseFilter, ENABLE);//开启数字滤波功能,避免干扰影响
    /*Enable RX && RX interupt function*/
    //    USART_FuncCmd(VSUSARTX, UsartTx, Enable);
    USART_FuncCmd(VSUSARTX, USART_RX, ENABLE);
    USART_FuncCmd(VSUSARTX, USART_INT_RX, ENABLE);
}

/**
 *******************************************************************************
 ** \brief USART RX irq callback function.
 **
 ** \param [in] None
 **
 ** \retval None
 **
 ******************************************************************************/
static void VsUsartRxIrqCallback(void)
{
    uint16_t CRC_Tmp;
    uint16_t CRC_RX;
    uint8_t TempRxDate;
    if (SET == USART_GetStatus(VSUSARTX, USART_FLAG_FRAME_ERR))
    {
        USART_ClearStatus(VSUSARTX, USART_FLAG_FRAME_ERR);
    }
    else if (SET == USART_GetStatus(VSUSARTX, USART_FLAG_PARITY_ERR))
    {
        USART_ClearStatus(VSUSARTX, USART_FLAG_PARITY_ERR);
    }
    else if (SET == USART_GetStatus(VSUSARTX, USART_FLAG_OVERRUN))
    {
        USART_ClearStatus(VSUSARTX, USART_FLAG_OVERRUN);
    }
    else
    {
        TempRxDate                   = USART_ReadData(VSUSARTX);
        VsRxVar.RxBuf[VsRxVar.RxCnt] = TempRxDate;    // acquire data
        VsRxVar.RxCnt++;
        /* Check if buffer full */
        if (VsRxVar.RxCnt == RX_COUNT_MAX)
        {
            VsRxVar.RxCnt = 0;
            CRC_Tmp       = CrcCheck(VsRxVar.RxBuf, 16);    // CRC Calculation
            CRC_RX        = ((uint16_t)VsRxVar.RxBuf[RX_COUNT_MAX - 1] << 8) + VsRxVar.RxBuf[RX_COUNT_MAX - 2];
            if (CRC_Tmp == CRC_RX)
            {
                VsRxVar.Addr[0]      = (uint16_t)(VsRxVar.RxBuf[0] | VsRxVar.RxBuf[1] << 8);
                VsRxVar.Addr[1]      = (uint16_t)(VsRxVar.RxBuf[4] | VsRxVar.RxBuf[5] << 8);
                VsRxVar.Addr[2]      = (uint16_t)(VsRxVar.RxBuf[8] | VsRxVar.RxBuf[9] << 8);
                VsRxVar.Addr[3]      = (uint16_t)(VsRxVar.RxBuf[12] | VsRxVar.RxBuf[13] << 8);
                VsRxVar.RxFinishFlag = 1;
            }
        }
    }
}

/**
 *******************************************************************************
 ** \brief USART TX irq callback function.
 **
 ** \param [in] None
 **
 ** \retval None
 **
 ******************************************************************************/
static void VsUsartTxIrqCallback(void)
{
#if !USE_VS_LOG_FUN
    if (VsTxVar.TxCnt < TX_COUNT_MAX)
    {
        // while(UUART_IS_TX_FULL(UUART0));  /* Wait Tx is not full to transmit data */
        USART_WriteData(VSUSARTX, VsTxVar.TxBuf[VsTxVar.TxCnt]);
        VsTxVar.TxCnt++;
    }
    else
    {
        //        while(1 != USART_GetStatus(VSUSARTX, UsartTxComplete));//必须要等全部发送完成才能关中断

        //        USART_FuncCmd(VSUSARTX, UsartTxAndTxEmptyInt, Disable);  //发送缓冲区空中断，关闭
        //        VsTxVar.TxFinishFlag = 1;
        USART_FuncCmd(VSUSARTX, USART_INT_TX_EMPTY, DISABLE);
        USART_FuncCmd(VSUSARTX, USART_INT_TX_CPLT, ENABLE);
    }
#endif
}

/**
 *******************************************************************************
 ** \brief USART TX irq callback function.
 **
 ** \param [in] None
 **
 ** \retval None
 **
 ******************************************************************************/
void VsUsartTCIrqCallback(void)
{
#if !USE_VS_LOG_FUN
    VsTxVar.TxFinishFlag = 1;
    USART_FuncCmd(VSUSARTX, USART_INT_TX_CPLT, DISABLE);
    USART_FuncCmd(VSUSARTX, USART_TX, DISABLE);
#endif
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
void VsUsartErrIrqCallback(void)
{
    if (SET == USART_GetStatus(VSUSARTX, USART_FLAG_FRAME_ERR))
    {
        USART_ClearStatus(VSUSARTX, USART_FLAG_FRAME_ERR);
    }
    if (SET == USART_GetStatus(VSUSARTX, USART_FLAG_PARITY_ERR))
    {
        USART_ClearStatus(VSUSARTX, USART_FLAG_PARITY_ERR);
    }
    if (SET == USART_GetStatus(VSUSARTX, USART_FLAG_OVERRUN))
    {
        USART_ClearStatus(VSUSARTX, USART_FLAG_OVERRUN);
    }
}


//==============================================================================
// Function:			VisualScope()
// Description:		Visual Scope
// Inputs:			Void
// Update Record：   V1.00： Deletion xxx processing
//==============================================================================
void VisualScope(void)
{
    uint16_t CRC_Tmp;
    uint8_t i;
    static uint32_t VSTimeoutCnt = 0;

    if (VsRxVar.RxCnt > 0)
    {
        VSTimeoutCnt++;
    }

    if (VSTimeoutCnt >= 1000)
    {
        VSTimeoutCnt  = 0;
        VsRxVar.RxCnt = 0;
    }

    if (VsRxVar.RxFinishFlag)
    {
        ChxValueTable();    // 通道数据选择
        // ------------------------------------------------------------
        // Visual scope
        // ------------------------------------------------------------
        VsTxVar.VsCh[0] = VsTemp[0];
        VsTxVar.VsCh[1] = VsTemp[1];
        VsTxVar.VsCh[2] = VsTemp[2];
        VsTxVar.VsCh[3] = VsTemp[3];
        // ============================================================
        // OnLineSendData(VsTxVar.VsCh);
        // ============================================================
        for (i = 0; i < 4; i++)
        {
            VsTxVar.TxBuf[2 * i]     = VsTxVar.VsCh[i] & 0x00FF;           // L8bit;
            VsTxVar.TxBuf[2 * i + 1] = (VsTxVar.VsCh[i] >> 8) & 0x00FF;    // H8bit
        }

        // CRC 校验计算
        CRC_Tmp          = CrcCheck(VsTxVar.TxBuf, 8);
        VsTxVar.TxBuf[8] = CRC_Tmp & 0xff;
        VsTxVar.TxBuf[9] = CRC_Tmp >> 8;

        // TX中断发送10Bytes数据
        VsTxVar.TxCnt = 0;
        USART_FuncCmd(VSUSARTX, USART_INT_TX_CPLT, DISABLE);
        USART_FuncCmd(VSUSARTX, USART_TX, DISABLE);
        USART_FuncCmd(VSUSARTX, USART_TX | USART_INT_TX_EMPTY,
                      ENABLE);    // 发送缓冲区空中断 //使能USART1中断:发送缓冲区空中断
    }
}

//==============================================================================
// Function:			VSInit()
// Description:		Initialize VS
// Inputs:			void SoftwareInit(void)
// Update Record：   V1.00： Deletion xxx processing
//==============================================================================
void VSInit(void)
{
    // 参数初始化
    VsRxVar.RxCnt        = 0;
    VsRxVar.RxFinishFlag = 0;
    VsTxVar.TxFinishFlag = 1;
}

//==============================================================================
// Function:			CrcCheck()
// Description:		Crc
// Inputs:			Void
// Update Record：   V1.00： Deletion xxx processing
//==============================================================================
uint16_t CrcCheck(uint8_t *Buf, uint16_t CRC_CNT)    // 44us
{
    uint16_t CRC_Temp;
    uint16_t i, j;
    CRC_Temp = 0xffff;

    for (i = 0; i < CRC_CNT; i++)
    {
        CRC_Temp ^= Buf[i];
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

//==============================================================================
// Function:			ChxValueTable()
// Description:		ChxValueTable
// Inputs:			Void
// Update Record：   V1.00： Deletion xxx processing
//==============================================================================
void ChxValueTable(void)
{
    int16_t i;
    int16_t temp;
    for (i = 0; i < 4; i++)    // 四通道上载数据赋值
    {
        // 步进
        if ((VsRxVar.Addr[i] & 0xF000) == 0x1000)
        {
            // 提取步进ID
            temp = VsRxVar.Addr[i] & 0x0F;
            if (temp < NODE_ID1 || temp > NODE_ID8)
            {
                temp = 0;
            }

            switch (VsRxVar.Addr[i] & 0xF00)
            {
            case 0x000:    // 报错号
                VsTemp[i] = SpiBusMontior[temp][0] * 100;
                break;
            case 0x100:    // 反馈位置
                VsTemp[i] = STEP_RAW_POSITION(temp);
                break;
            case 0x200:    // 找零后位置
                VsTemp[i] = STEP_POSITION(temp);
                break;
            case 0x300:    // 指令
                VsTemp[i] = SpiBusMaster.PdoTxId[temp].bit.Data;
                break;
            case 0x400:    // 零点位置
                VsTemp[i] = Step[temp].RESET.ZeroPos;
                break;
            case 0x500:    // 方向
                VsTemp[i] = SpiBusMaster.PdoTxId[temp].bit.RotationDir * 100;
                break;
            case 0x600:    // 使能
                VsTemp[i] = SpiBusMaster.PdoTxId[temp].bit.Enable * 100;
                break;
            case 0x700:    // 运行
                VsTemp[i] = StepRunning(temp) * 1000;
                break;
            case 0x800:
                VsTemp[i] = Step[temp].POS_BY_SPEED.AchievePos;
                break;
            case 0x900:
                VsTemp[i] = Step[temp].POS_BY_SPEED.TargetPos;
                break;
            default:
                VsTemp[i] = -1;
                break;
            }
            continue;
        }

        // S参数
        if ((VsRxVar.Addr[i] & 0xF000) == 0x2000)
        {
            if ((VsRxVar.Addr[i] & 0x0FFF) < 128)
            {
                VsTemp[i] = MBSParam[VsRxVar.Addr[i] & 0x0FFF];
            }
            else
            {
                VsTemp[i] = -1;
            }
            continue;
        }

        // P参数
        if ((VsRxVar.Addr[i] & 0xF000) == 0x3000)
        {
            if ((VsRxVar.Addr[i] & 0x0FFF) < 128)
            {
                VsTemp[i] = MBPParam[VsRxVar.Addr[i] & 0x0FFF];
            }
            else
            {
                VsTemp[i] = -1;
            }
            continue;
        }

        // 监控
        if ((VsRxVar.Addr[i] & 0xF000) == 0x4000)
        {
            if ((VsRxVar.Addr[i] & 0x0FFF) < 50)
            {
                VsTemp[i] = MBMonitor[VsRxVar.Addr[i] & 0x0FFF];
            }
            else
            {
                VsTemp[i] = -1;
            }
            continue;
        }

        // Y参数
        if ((VsRxVar.Addr[i] & 0xF000) == 0x5000)
        {
            if ((VsRxVar.Addr[i] & 0x0FFF) < 128)
            {
                VsTemp[i] = MBYParam[VsRxVar.Addr[i] & 0x0FFF];
            }
            else
            {
                VsTemp[i] = -1;
            }
            continue;
        }

        switch (VsRxVar.Addr[i])
        {
        /******** 系统测试 *******/
        case 0x01:
            VsTemp[i] = UseTime1Us;
            break;
        /******** SPI主板 *******/
        case 0x50:
            VsTemp[i] = 100 * UtilitySpiBusMaster.SelectChipId;
            break;
        case 0x51:
            VsTemp[i] = 100 * UtilitySpiBusMaster.SelectChipIdOld;
            break;
        case 0x52:
            VsTemp[i] = UtilitySpiBusMaster.PdoRxId[NODE_ID1].bit.Data;
            break;
        case 0x53:
            VsTemp[i] = UtilitySpiBusMaster.PdoTxId[NODE_ID1].bit.Data;
            break;
        case 0x54:
            VsTemp[i] = UtilitySpiBusMaster.CrcErr;
            break;
        case 0x55:
            VsTemp[i] = ErrFF;
            break;
        case 0x56:
            VsTemp[i] = Err00;
            break;
        /******** SPI步进 *******/
        case 0x60:
            VsTemp[i] = SpiBusMaster.PdoRxId[NODE_ID1].all;
            break;
        case 0x61:
            VsTemp[i] = SpiBusMaster.SdoRxId[NODE_ID1].all;
            break;
        case 0x62:
            VsTemp[i] = SpiBusMaster.CrcErr;
            break;
        /******** 工艺 *******/
        case 0x70:
            VsTemp[i] = 10 * MachineModel;
            break;
        case 0x71:
            VsTemp[i] = 10 * SewingModel;
            break;
        case 0x72:
            VsTemp[i] = 10 * SewingSubStatus;
            break;
        case 0x73:
            VsTemp[i] = SewingDist;
            break;
        case 0x74:
            VsTemp[i] = NeedleCount;
            break;
        case 0x75:
            VsTemp[i] = SystemErrGet();
            break;
        case 0x76:
            VsTemp[i] = StepPluseTo01mm(STEP_ID_LEFT_FEEDING, SewingDistOld);
            break;
        /******** 同步 *******/
        case 0x80:
            VsTemp[i] = Sync.MainAxisErr;
            break;
        case 0x81:
            VsTemp[i] = Sync.SyncFeed.Feed1AbPos;
            break;
        case 0x82:
            VsTemp[i] = Sync.SyncFeed.Feed2AbPos;
            break;
            //        case 0x83:
            //            VsTemp[i] = Sync.SyncFeed.Delta;
            //            break;
            //        case 0x84:
            //            VsTemp[i] = Sync.SyncFeed.Remain;
            //            break;
        case 0x85:
            VsTemp[i] = Sync.SyncServo.Delta;
            break;
        case 0x86:
            VsTemp[i] = Sync.SyncServo.Remain;
            break;
        /******** 主轴 *******/
        case 0x90:
            VsTemp[i] = MainAxis.Encoder.NowRawCnt;
            break;
        case 0x91:
            VsTemp[i] = MainAxis.Encoder.Speed;
            break;
        case 0x92:
            VsTemp[i] = MainAxis.CTRL.Pedal * 100;
            break;
        case 0x93:
            VsTemp[i] = MainAxis.CTRL.PedalCmd * 100;
            break;
        case 0x94:
            VsTemp[i] = MainAxis.CTRL.Speed;
            break;
        case 0x95:
            VsTemp[i] = MainAxis.Encoder.Degree;    // 主轴角度
            break;
        case 0x96:
            VsTemp[i] = MainAxis.Encoder.ZSignal * 100;    // Z信号
            break;
        case 0x97:
            VsTemp[i] = MainAxis.Encoder.Err[MainAxis.Encoder.ErrIndex];
            break;
        case 0x98:
            VsTemp[i] = MainAxis.Encoder.Cnt;
            break;
        case 0x99:
            VsTemp[i] = MainAxis.Ramp.Cnt;
            break;
        /******** 伺服 *******/
        case 0xA0:
            VsTemp[i] = ServoMotor.NowPosition;
            break;
        case 0xA1:
            VsTemp[i] = ServoMotor.NowPosition * 3600 / 1440;    // 伺服角度
            break;
        case 0xA2:
            VsTemp[i] = ServoMotor.MotionState;
            break;
        case 0xA3:
            VsTemp[i] = ServoMotor.ResetStatus;
            break;
        /******** 测试 *******/
        case 0xB0:
            VsTemp[i] = TestCnt;
            break;
        case 0xB1:
            VsTemp[i] = Sensor[SENSOR_ID_STRUCT_LINE].AnalogValue;
            break;
        case 0xB2:
            VsTemp[i] = Sensor[SENSOR_ID_EXPAND].AnalogValue;
            break;
        case 0xB3:
            VsTemp[i] = TestFlag1;
            break;
        case 0xB4:
            VsTemp[i] = TestFlag2;
            break;
        case 0xB5:
            VsTemp[i] = TestFlag3;
            break;
        case 0xB6:
            VsTemp[i] = Sensor[SENSOR_ID_STRUCT_LINE].Signal;
            break;
        case 0xB7:
            VsTemp[i] = Sensor[SENSOR_ID_EXPAND].Signal;
            break;
        case 0xB8:
            VsTemp[i] = Sensor[SENSOR_ID_SENSOR1].Signal;
            break;
        case 0xB9:
            VsTemp[i] = Sensor[SENSOR_ID_SENSOR2].Signal;
            break;
        case 0xBA:
            VsTemp[i] = Sensor[SENSOR_ID_SENSOR3].Signal;
            break;
        case 0xBC:
            VsTemp[i] = CorrSensorSelet;
            break;
        case 0xBD:
            VsTemp[i] = StructLineThreshold;
            break;
        case 0xBE:
            VsTemp[i] = StructLineMaxValue;
            break;
        case 0xBF:
            VsTemp[i] = StructLineMinValue;
            break;
        case 0xC1:
            VsTemp[i] = Sensor[SENSOR_ID_SENSOR1_2_ORIGIN].Signal;
            break;
        case 0xC2:
            VsTemp[i] = Sensor[SENSOR_ID_SENSOR3_ORIGIN].Signal;
            break;
        case 0xC3:
            VsTemp[i] = Sensor[SENSOR_ID_TABLE_ORIGIN].Signal;
            break;
        case 0xC4:
            VsTemp[i] = Sensor[SENSOR_ID_EXPAND_ORIGIN].Signal;
            break;
        case 0xC5:
            VsTemp[i] = ValveStatus[VALVE_ID_GAUGE_3];
            break;
        case 0xC6:
            VsTemp[i] = ValveStatus[VALVE_ID_INVERT_SEAM_STRONG_BLOW];
            break;
        case 0xC7:
            VsTemp[i] = ValveStatus[VALVE_ID_INVERT_SEAM_WEAK_BLOW];
            break;
        case 0xC8:
            VsTemp[i] = ValveStatus[VALVE_ID_INVERT_SEAM];
            break;
        case 0xC9:
            VsTemp[i] = ValveStatus[VALVE_ID_MACHINE_PRESSER];
            break;
        case 0xCA:
            VsTemp[i] = ValveStatus[VALVE_ID_GAUGE_1];
            break;
        case 0xCB:
            VsTemp[i] = ValveStatus[VALVE_ID_GAUGE_2];
            break;
        case 0xCC:
            VsTemp[i] = Sync.SyncServo.GlobalErr;
            break;
        default:
            break;
        }
    }
}

//================================================================================
// Function:			VSUartSendByte()
// Description:	发送一个字节数据（不能用这个函数发多个字节数据，会影响其他程序执行）
// Inputs:
// Outputs:
// Description:
//================================================================================
void VSUartSendByte(uint8_t Data)
{
    while (1 != USART_GetStatus(VSUSARTX, USART_FLAG_TX_EMPTY));    // 获取USART状态寄存器标志位:发送数据缓冲区空
    USART_WriteData(VSUSARTX, Data);
    USART_FuncCmd(VSUSARTX, USART_INT_TX_EMPTY, ENABLE);
    VsTxVar.TxCnt = 1;
    VsTxVar.TxNum = 1;
}

//================================================================================
// Function:			VSUartSendnBytes()
// Description:	发送多个字节的数据
// Inputs:
// Outputs:
// Description:
//================================================================================
void VSUartSendnBytes(uint8_t *data, uint8_t len)
{
    uint16_t i;

    while (1 != USART_GetStatus(VSUSARTX, USART_FLAG_TX_EMPTY));    // 获取USART状态寄存器标志位:发送数据缓冲区空

    for (i = 0; i < len; i++)
    {
        VsTxVar.TxBuf[i] = data[i];
    }
    VsTxVar.TxNum = len;    // 发送数据个数赋值
    VsTxVar.TxCnt = 1;      // 表示已发送1个数据
    USART_WriteData(VSUSARTX, data[0]);
    USART_FuncCmd(VSUSARTX, USART_TX | USART_INT_TX_EMPTY, ENABLE);
}

void DebugSerialComm(uint8_t Type)
{
    static uint16_t CycleCnt = 0;
    CycleCnt++;

    switch (Type)
    {
    case 0:
        VisualScope();
        break;
    case 1:    // 调试log发送函数
        if (CycleCnt < 100)
            return;    // 10ms周期打印log报文
        CycleCnt = 0;
        break;
    default:
        VisualScope();
        break;
    }
}


void Log(const char *format, ...)
{
#if 0
    uint8_t len;
    va_list ap;
    va_start(ap,format);
    char buff[1024];
    vsnprintf(buff,80,format,ap);
    va_end(ap);
    len = strlen(buff);
    // 添加

    VSUartSendnBytes((uint8_t *)buff, len);
    //DDL_DelayMS(200);
#endif
}

int fputc(int ch, FILE *f)
{
#if USE_VS_LOG_FUN
    while (1 != USART_GetStatus(VSUSARTX, USART_FLAG_TX_EMPTY));    // 获取USART状态寄存器标志位:发送数据缓冲区空
    USART_WriteData(VSUSARTX, (uint8_t)ch);
    USART_FuncCmd(VSUSARTX, USART_TX | USART_INT_TX_EMPTY, ENABLE);
#endif
    return (ch);
}
