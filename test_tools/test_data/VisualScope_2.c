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

//==============================================================================
// Declare functions
//==============================================================================
void ChxValueTable(void);

VS_RX_VAR VsRxVar;
VS_TX_VAR VsTxVar;
void VsUsartRxIrqCallback(void);
void VsUsartTxIrqCallback(void);
void VsUsartTCIrqCallback(void);
void VsUsartErrIrqCallback(void);
uint8_t TxCountMax = 18;		//240625-1
uint8_t RxCountMax = 34;
uint8_t CycleCountNum = 8;
int16_t VsTemp[8];
int16_t TestFlag1 = 0;
int16_t TestFlag2 = 0;
int16_t TestFlag3 = 0;
int16_t TestFlag4 = 0;
int16_t TestFlag5 = 0;
int16_t TestFlag6 = 0;
int16_t TestFlag7 = 0;
int16_t TestFlag8 = 0;
int16_t TestFlag9 = 0;
int16_t TestFlag44 = 0;
int16_t TestFlag55 = 0;
int16_t TestFlag66 = 0;
int16_t TestFlag77 = 0;
int16_t TestFlag88 = 0;
int16_t TestFlag99 = 0;

int16_t SX_flag = 0;
int16_t BX_flag = 0;
int16_t QX_flag = 0;


int16_t TestFlagLength = 0;


int16_t TestFlag111= 0;
int16_t TestFlag222 = 0;
int16_t TestFlag333 = 0;
//=================================================
//Function:			Hc32f46xUsartConfig()
//Description:		
//Inputs:			Void
//Outputs:			Void
//Update Record：   V1.00： Deletion xxx processing
//================================================================================
void VsUsartInit(uint32_t bdr)
{
    en_result_t enRet = Ok;
    stc_irq_regi_conf_t stcIrqRegiCfg;
  
    const stc_usart_uart_init_t stcInitCfg = {
        UsartIntClkCkNoOutput,                      ///< Select internal clock source and don't output clock.
        UsartClkDiv_1,
        UsartDataBits8,
        UsartDataLsbFirst,
        UsartOneStopBit,
        UsartParityNone,
        UsartSampleBit8,
        UsartStartBitFallEdge,
        UsartRtsEnable,
    };

    /* Enable peripheral clock */
    PWC_Fcg1PeriphClockCmd(VSUSARTX_PWC, Enable);
    
    /* Initialize USART IO */
    PORT_SetFunc(VISCOPE_RX_PORT, VISCOPE_RX_PIN, VISCOPE_RX_FUNC, Disable);
    PORT_SetFunc(VISCOPE_TX_PORT, VISCOPE_TX_PIN, VISCOPE_TX_FUNC, Disable);
    
    enRet = USART_UART_Init(VSUSARTX, &stcInitCfg);
    if (enRet != Ok)
    {
        while (1);
    }

    /* Set baudrate */
    USART_SetClockDiv(VSUSARTX,UsartClkDiv_1);//不分频设置较小的波特率会失败
    enRet = USART_SetBaudrate(VSUSARTX, bdr);
    if (enRet != Ok)
    {
        while (1);
    }
    
    
    
    #if (VS_TRANS_SEL==DMA_MODE)     
    /*Enable RX && RX interupt function*/
    USART_FuncCmd(VSUSARTX, UsartRx, Enable);
    USART_FuncCmd(VSUSARTX, UsartTx, Enable);
    #else
     /* Set USART RX IRQ */
    stcIrqRegiCfg.enIRQn            = VECT_NUM_VSUSART_RX;
    stcIrqRegiCfg.pfnCallback       = &VsUsartRxIrqCallback;
    stcIrqRegiCfg.enIntSrc          = VSUSART_RI_NUM;
    enIrqRegistration(&stcIrqRegiCfg);
    NVIC_SetPriority(stcIrqRegiCfg.enIRQn, DDL_IRQ_PRIORITY_15);
    NVIC_ClearPendingIRQ(stcIrqRegiCfg.enIRQn);
    NVIC_EnableIRQ(stcIrqRegiCfg.enIRQn);

    /* Set USART TX IRQ */
    stcIrqRegiCfg.enIRQn            = VECT_NUM_VSUSART_TX;
    stcIrqRegiCfg.pfnCallback       = &VsUsartTxIrqCallback;
    stcIrqRegiCfg.enIntSrc          = VSUSART_TI_NUM;//发送寄存器空中断
    enIrqRegistration(&stcIrqRegiCfg);
    NVIC_SetPriority(stcIrqRegiCfg.enIRQn, DDL_IRQ_PRIORITY_15);
    NVIC_ClearPendingIRQ(stcIrqRegiCfg.enIRQn);
    NVIC_EnableIRQ(stcIrqRegiCfg.enIRQn);
    
    /* Set USART TC IRQ */
    stcIrqRegiCfg.enIRQn            = VECT_NUM_VSUSART_TC;
    stcIrqRegiCfg.pfnCallback       = &VsUsartTCIrqCallback;
    stcIrqRegiCfg.enIntSrc          = VSUSART_TC_NUM;//发送寄存器空中断
    enIrqRegistration(&stcIrqRegiCfg);
    NVIC_SetPriority(stcIrqRegiCfg.enIRQn, Int000_IRQn);//DDL_IRQ_PRIORITY_15);
    NVIC_ClearPendingIRQ(stcIrqRegiCfg.enIRQn);
    NVIC_EnableIRQ(stcIrqRegiCfg.enIRQn);

		stcIrqRegiCfg.enIRQn            = VECT_NUM_VSUSART_RXERR;
    stcIrqRegiCfg.pfnCallback       = &VsUsartErrIrqCallback;
    stcIrqRegiCfg.enIntSrc          = VSUSART_EI_NUM;
    enIrqRegistration(&stcIrqRegiCfg);
    NVIC_SetPriority(stcIrqRegiCfg.enIRQn, DDL_IRQ_PRIORITY_15);
    NVIC_ClearPendingIRQ(stcIrqRegiCfg.enIRQn);
    NVIC_EnableIRQ(stcIrqRegiCfg.enIRQn);
		
		
		USART_FuncCmd(VSUSARTX, UsartNoiseFilter, Enable);//开启数字滤波功能,避免干扰影响
    /*Enable RX && RX interupt function*/
//    USART_FuncCmd(VSUSARTX, UsartTx, Enable);
    USART_FuncCmd(VSUSARTX, UsartRx, Enable);
    USART_FuncCmd(VSUSARTX, UsartRxInt, Enable); 
    #endif
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
    uint16_t  CRC_Tmp;
    uint16_t  CRC_RX;
    uint8_t TempRxDate;
    if(Set == USART_GetStatus(VSUSARTX, UsartFrameErr))
    {
        USART_ClearStatus(VSUSARTX, UsartFrameErr);
    }
    else if (Set == USART_GetStatus(VSUSARTX, UsartParityErr))
    {
        USART_ClearStatus(VSUSARTX, UsartParityErr);
    }
    else if (Set == USART_GetStatus(VSUSARTX, UsartOverrunErr))
    {
        USART_ClearStatus(VSUSARTX, UsartOverrunErr);
    }
    else
    {
        TempRxDate = USART_RecData(VSUSARTX);
        VsRxVar.RxBuf[VsRxVar.RxCnt] = TempRxDate;				//acquire data
        VsRxVar.RxCnt++;

            /* Check if buffer full */
        if(VsRxVar.RxCnt == RxCountMax)		//240625-1
        {
              VsRxVar.RxCnt = 0;
              CRC_Tmp     =  CrcCheck(VsRxVar.RxBuf,(RxCountMax-2));  	            //CRC Calculation
              CRC_RX      = ((uint16_t)VsRxVar.RxBuf[RxCountMax-1]<<8) + VsRxVar.RxBuf[RxCountMax-2];
              if(CRC_Tmp == CRC_RX)
              {
                  VsRxVar.Addr[0] = ((uint32_t)(VsRxVar.RxBuf[0x3])<<24)|((uint32_t)(VsRxVar.RxBuf[0x2])<<16)|((uint32_t)(VsRxVar.RxBuf[0x1])<<8)|VsRxVar.RxBuf[0x0];//(uint16_t)VsRxVar.RxBuf[0];
                  VsRxVar.Addr[1] = ((uint32_t)(VsRxVar.RxBuf[0x7])<<24)|((uint32_t)(VsRxVar.RxBuf[0x6])<<16)|((uint32_t)(VsRxVar.RxBuf[0x5])<<8)|VsRxVar.RxBuf[0x4];//(uint16_t)VsRxVar.RxBuf[4];
                  VsRxVar.Addr[2] = ((uint32_t)(VsRxVar.RxBuf[0xB])<<24)|((uint32_t)(VsRxVar.RxBuf[0xA])<<16)|((uint32_t)(VsRxVar.RxBuf[0x9])<<8)|VsRxVar.RxBuf[0x8];
                   VsRxVar.Addr[3] = ((uint32_t)(VsRxVar.RxBuf[0xF])<<24)|((uint32_t)(VsRxVar.RxBuf[0xE])<<16)|((uint32_t)(VsRxVar.RxBuf[0xD])<<8)|VsRxVar.RxBuf[0xC];
				  if(PedalPortOpt == VISUALSCOPE8CH)		//240625-1
				  {		   
			           VsRxVar.Addr[4] = ((uint32_t)(VsRxVar.RxBuf[0x13])<<24)|((uint32_t)(VsRxVar.RxBuf[0x12])<<16)|((uint32_t)(VsRxVar.RxBuf[0x11])<<8)|VsRxVar.RxBuf[0x10];//(uint16_t)VsRxVar.RxBuf[0];
			           VsRxVar.Addr[5] = ((uint32_t)(VsRxVar.RxBuf[0x17])<<24)|((uint32_t)(VsRxVar.RxBuf[0x16])<<16)|((uint32_t)(VsRxVar.RxBuf[0x15])<<8)|VsRxVar.RxBuf[0x14];//(uint16_t)VsRxVar.RxBuf[4];
			           VsRxVar.Addr[6] = ((uint32_t)(VsRxVar.RxBuf[0x1B])<<24)|((uint32_t)(VsRxVar.RxBuf[0x1A])<<16)|((uint32_t)(VsRxVar.RxBuf[0x19])<<8)|VsRxVar.RxBuf[0x18];
			           VsRxVar.Addr[7] = ((uint32_t)(VsRxVar.RxBuf[0x1F])<<24)|((uint32_t)(VsRxVar.RxBuf[0x1E])<<16)|((uint32_t)(VsRxVar.RxBuf[0x1D])<<8)|VsRxVar.RxBuf[0x1C];
				  }
                  VsRxVar.RxFinishFlag = 1;
//                  if((VsRxVar.Addr[0]) || (VsRxVar.Addr[1]))		//上位机启停
//                  {
//                    VsRxVar.RxFinishFlag = 1;
//                  }
//                  else
//                  {
//                    VsRxVar.RxFinishFlag = 0;
//                  }
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
    if(VsTxVar.TxCnt < TxCountMax)
		{
        //while(UUART_IS_TX_FULL(UUART0));  /* Wait Tx is not full to transmit data */
        USART_SendData(VSUSARTX, VsTxVar.TxBuf[VsTxVar.TxCnt]);
        VsTxVar.TxCnt++;
		}
		else
		{
//        while(1 != USART_GetStatus(VSUSARTX, UsartTxComplete));//必须要等全部发送完成才能关中断
        
//        USART_FuncCmd(VSUSARTX, UsartTxAndTxEmptyInt, Disable);  //发送缓冲区空中断，关闭
//        VsTxVar.TxFinishFlag = 1;
        USART_FuncCmd(VSUSARTX, UsartTxEmptyInt, Disable);
        USART_FuncCmd(VSUSARTX, UsartTxCmpltInt, Enable);
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
void VsUsartTCIrqCallback(void)
{ 
    VsTxVar.TxFinishFlag = 1;
    USART_FuncCmd(VSUSARTX, UsartTxCmpltInt, Disable);
    USART_FuncCmd(VSUSARTX, UsartTx, Disable);
//    SAFEKEYTEST_OFF;
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
    if (Set == USART_GetStatus(VSUSARTX, UsartFrameErr))
    {
        USART_ClearStatus(VSUSARTX, UsartFrameErr);
    }
    if (Set == USART_GetStatus(VSUSARTX, UsartParityErr))
    {
        USART_ClearStatus(VSUSARTX, UsartParityErr);
    }
    if (Set == USART_GetStatus(VSUSARTX, UsartOverrunErr))
    {
        USART_ClearStatus(VSUSARTX, UsartOverrunErr);
    }
}


//==============================================================================
//Function:			VisualScope()
//Description:		Visual Scope
//Inputs:			Void
//Update Record：   V1.00： Deletion xxx processing
//==============================================================================
void VisualScope(void)
{
    uint16_t  CRC_Tmp;
    uint8_t   i;
    


#if (VS_TRANS_SEL==DMA_MODE)  
    DmaUsart.DMA2RecvProcess();      //231108
#endif
    if(VsRxVar.RxFinishFlag)
    {
//        if(VsTxVar.TxFinishFlag)
//        {
//            VsTxVar.TxFinishFlag = 0;
            
            ChxValueTable();		//通道数据选择
            // ------------------------------------------------------------
            // Visual scope
            // ------------------------------------------------------------
            VsTxVar.VsCh[0]  =  VsTemp[0];
            VsTxVar.VsCh[1]  =  VsTemp[1];
            VsTxVar.VsCh[2]  =  VsTemp[2];
            VsTxVar.VsCh[3]  =  VsTemp[3];
			if(PedalPortOpt == VISUALSCOPE8CH)		//240625-1
			{
		        VsTxVar.VsCh[4]  =  VsTemp[4];
		        VsTxVar.VsCh[5]  =  VsTemp[5];
		        VsTxVar.VsCh[6]  =  VsTemp[6];
		        VsTxVar.VsCh[7]  =  VsTemp[7];	
			}
            // ============================================================
            //OnLineSendData(VsTxVar.VsCh);
            // ============================================================
            for(i=0; i<CycleCountNum; i++)
            {
                VsTxVar.TxBuf[2*i] = VsTxVar.VsCh[i] & 0x00FF;					// L8bit;
                VsTxVar.TxBuf[2*i+1] = (VsTxVar.VsCh[i]>>8 ) & 0x00FF;			// H8bit
            }

            // CRC 校验计算
            CRC_Tmp         = CrcCheck(VsTxVar.TxBuf,(TxCountMax-2));
            VsTxVar.TxBuf[TxCountMax-2]  = CRC_Tmp&0xff;
            VsTxVar.TxBuf[TxCountMax-1]  = CRC_Tmp>>8;
          
            // TX中断发送10Bytes数据
           
//            USART_SendData(VSUSARTX, VsTxVar.TxBuf[0]);
//          SAFEKEYTEST_ON;
            
            
             #if (VS_TRANS_SEL==DMA_MODE)     
                DmaUsart.DMA1Channel();
             #else
            
             VsTxVar.TxCnt = 0;
            USART_FuncCmd(VSUSARTX, UsartTxCmpltInt, Disable);
            USART_FuncCmd(VSUSARTX, UsartTx, Disable);
            USART_FuncCmd(VSUSARTX, UsartTxAndTxEmptyInt, Enable);  //发送缓冲区空中断 //使能USART1中断:发送缓冲区空中断
             #endif
//        }
    }
}

//==============================================================================
//Function:			VSInit()
//Description:		Initialize VS
//Inputs:			void SoftwareInit(void)
//Update Record：   V1.00： Deletion xxx processing
//==============================================================================
void VSInit(void)
{
    // 参数初始化
    VsRxVar.RxCnt = 0;
    VsRxVar.RxFinishFlag = 0;
    VsTxVar.TxFinishFlag = 1;
}

//==============================================================================
//Function:			CrcCheck()
//Description:		Crc
//Inputs:			Void
//Update Record：   V1.00： Deletion xxx processing
//==============================================================================
uint16_t CrcCheck(uint8_t  *Buf, uint16_t CRC_CNT)//44us
{
	uint16_t CRC_Temp;
	uint16_t i,j;
    CRC_Temp = 0xffff;

    for (i=0;i<CRC_CNT; i++)
    {
        CRC_Temp ^= Buf[i];
        for (j=0;j<8;j++)
        {
            if (CRC_Temp & 0x01)
                CRC_Temp = (CRC_Temp >>1 ) ^ 0xa001;
            else
                CRC_Temp = CRC_Temp >> 1;
        }
    }
    return(CRC_Temp);
}

//==============================================================================
//Function:			ChxValueTable()
//Description:		ChxValueTable
//Inputs:			Void
//Update Record：   V1.00： Deletion xxx processing
//==============================================================================
void ChxValueTable(void)
{
	int16_t i;
//   static INT16U j;
   static uint32_t ErrDataCnt = 0;
   int16_t  Index;
   
    for(i=0;i<CycleCountNum;i++)		//四通道上载数据赋值		//240625-1
    {
			switch(VsRxVar.Addr[i])
      {
       case 0x0:// 当前工作状态 
				VsTemp[i] = ((int16_t)(WorkState.StateOut *100));  
				break;
				
			case 0x1:// 运动命令 
				VsTemp[i] = ((int16_t)(RunControl.Cmd * 100));  
				break;
			
			case 0x2:// 脚踏电压值 
				VsTemp[i] =((uint16_t) PedalMinid.Voltage);  
				break;

			case 0x3:// 速度给定
				 VsTemp[i] = ((int16_t) (_IQtoF(ServoPidSpeed.Ref) * 6000));  
				 break;	

			case 0x4:// 速度反馈
				 VsTemp[i] = ((int16_t) (_IQtoF(ServoPidSpeed.Fdb) * 6000));  
				 break;		

			case 0x5:// d轴电流给定
				 VsTemp[i] = ((int16_t)(_IQtoF(Servo_PidId.Ref) * 10000));   
				 break;	
			
			case 0x6:// d轴电流反馈
				 VsTemp[i] = ((int16_t)(_IQtoF(Servo_PidId.Fdb) * 10000));   
				 break;	
				
			case 0x7:// q轴电流给定
				 VsTemp[i] = ((int16_t)(_IQtoF(Servo_PidIq.Ref) * 10000));   
				 break;	
			
			case 0x8:// q轴电流反馈
				 VsTemp[i] = ((int16_t)(_IQtoF(Servo_PidIq.Fdb) * 10000));   
				 break;	

			case 0x9:// 中间停步骤
				 VsTemp[i] = ((int16_t)BreakStopStep*100);   
				 break;	
			
			case 0x10://电机机械位置
				 VsTemp[i] = ((int16_t)(_IQ16toF(ThtamUp)* 360)); 
				 break;	
				
			case 0x11://针距
				 VsTemp[i] = ((int16_t)(PresserMagnet.State)*100);   
				 break;	

			case 0x12://压脚状态
				 VsTemp[i] = ((int16_t)(Presser.State)*100);   
				 break;					
			
			case 0x13://当前距离目标点的角度
				 VsTemp[i] = ((int16_t)(ThtamDelta));   
				 break;	

			case 0x14://计针数
				 VsTemp[i] = ((int16_t)(TotalStitch.StitchCnt));   
				 break;	
				
			case 0x15://电机停车位置
				 VsTemp[i] = ((int16_t)(FlagAdjusUp*100));   
				 break;
	
			case 0x16://速度给定中间变量
				VsTemp[i] =	((int16_t)(_IQtoF(SpeedRef) * 6000));
				 break;	
			
			case 0x17://上电停车控制步骤
				 VsTemp[i] = ((int16_t)(PowerStopStep*100));   
				 break;	

			case 0x18://上电停车控制步骤
				 VsTemp[i] = ((int16_t)(PedalMinid.State *100));   
				 break;	
				
			case 0x19://程序运行点测试
				 VsTemp[i] = ((int16_t)(PowerStopStep*100));   
				 break;	
			
			case 0x20://当前距离停车角度
				 VsTemp[i] = ((int16_t)(ThtamDelta));   
				 break;	
			
			case 0x21://当前速度停下需要的角度
				 VsTemp[i] = ((int16_t)(ThtamStop));   
				 break;	
			
			case 0x22://剪线停车步骤
				 VsTemp[i] = ((int16_t)(TrimStopStep*100));   
				 break;	
				
			case 0x23://剪线停车状态
				 VsTemp[i] = ((int16_t)(StateTrimStop*100));   
				 break;

		    case 0x24:// 缝纫标识 
				VsTemp[i] = ((int16_t)(WorkState.FlagSewed *100));  
				break;
		   
			case 0x25:// 上电停车步骤 
				VsTemp[i] = ((int16_t)(PowerStopStep *100));  
				break;
				
			case 0x26:// 速度反馈 
				VsTemp[i] =	((signed int)(_IQtoF(SpeedFdb) * 6000)); 
				break;
				
			case 0x27:// 送布方向 
				VsTemp[i] = ((int16_t)(FeedControl.FeedDirect*100));  
				break;
				
			case 0x28:// 剪线电磁铁开关状态 
				VsTemp[i] = ((int16_t)(PortUartState.RxResult*100));  
				break;
				
			case 0x29:// 送布状态
				VsTemp[i] = ((int16_t)(FeedControl.FeedState*100));  
				break;

			case 0x30:// 固缝计针数
				VsTemp[i] = ((int16_t)(Stitch.StitchCnt*100));  
				break;
				
			case 0x31:// 前固缝缝制阶段
				VsTemp[i] = ((int16_t)(FTackingSew.SewingState*100));  
				break;	
			
			case 0x32:// 后固缝缝制阶段
				VsTemp[i] = ((int16_t)(BTackingSew.SewingState*100));  
				break;	
	
			case 0x33:// 自由缝过渡到后固缝的控制步骤
				VsTemp[i] = ((int16_t)(Sew2Tack*100));  
				break;
			
			case 0x34:// 细分速度给定
				VsTemp[i] = ((int16_t)(SpeedRealRef>>1));  
				break;
				
			case 0x35:// 缝纫模式
				VsTemp[i] = ((int16_t)(HmiSewParam.SewMode*100));  
				break;
			
			case 0x36:// 前固缝重复遍数
				VsTemp[i] = ((int16_t)(FTackingSew.RepeatCnt*100));  
				break;
				
			case 0x37:// 多段缝速度链接
				VsTemp[i] = ((int16_t)(NSegSew.SpeedLink*100));  
				break;
			
			case 0x38:// 多段缝状态标志
				VsTemp[i] = ((int16_t)(NSegSew.SewState *100));  
				break;
				
			case 0x39:// 软启动工作状态
				VsTemp[i] = ((int16_t)(SoftStart.SoftState *100));  
				break;	
				
			case 0x40:// 多段缝计针数
				VsTemp[i] = ((int16_t)(StitchOneSeg.StitchCnt *100));  
				break;	
						
			case 0x41:// 多段缝扎布标识
				VsTemp[i] = ((int16_t)(NSegSew.FlagPricked *100));  
				break;	
				
			case 0x42:// 补针状态标志
				VsTemp[i] = ((int16_t)(CompStitch.State *100));  
				break;	

			case 0x43:// 补针结束标志
				VsTemp[i] = ((int16_t)(CompStitch.Compend *100));  
				break;					
				
			case 0x44:// 歩进抬压脚控制步骤
				VsTemp[i] = ((int16_t)(StepPress.Step*100));  
				break;
			
			case 0x45:// 前固缝重复次数
				VsTemp[i] = ((int16_t)(FTackingSew.WsewTimes*100));
				break;
				
			case 0x46:// 前固模式
				VsTemp[i] = ((int16_t)(FTackingSew.Option*100));
				break;
				
			case 0x47:// 缝纫模式设置
				VsTemp[i] = ((int16_t)((HmiSewParam.HmiSewStyle & MSK_MODE_OPTION)*100));
				break;
				
			case 0x48:// 前密缝工作状态
				VsTemp[i] = ((int16_t)(FTShortLock.LockState*100));
				break;
				
			case 0x49:// 前密缝速度链接
				VsTemp[i] = ((int16_t)(FTShortLock.SpeedLink*100));
				break;
				
			case 0x50:// 前密缝针距
				VsTemp[i] = ((int16_t)(FTShortLock.StitchLength*100));
				break;
				
			case 0x51:// 密缝针数
				VsTemp[i] = ((int16_t)(LockStitch.StitchCnt*100));
				break;
				
			case 0x52:// 前密缝设置的针数
				VsTemp[i] = ((int16_t)(FTShortLock.Stitches*100));
				break;
				
			case 0x53:// 前密缝机械角度
				VsTemp[i] = ((int16_t)(FTShortLock.MechTheta>> 3));
				break;
				
			case 0x54:// 后密缝工作状态
				VsTemp[i] = ((int16_t)(BTShortLock.LockState*100));
				break;
				
			case 0x55:// 后密缝速度链接
				VsTemp[i] = ((int16_t)(BTShortLock.SpeedLink*100));
				break;
				
			case 0x56:// 后密缝针距
				VsTemp[i] = ((int16_t)(BTShortLock.StitchLength*100));
				break;
				
			case 0x57:// 密缝针数
				VsTemp[i] = ((int16_t)(FTShortLock.SewTimes*100));
				break;
				
			case 0x58:// 后密缝设置的针数
				VsTemp[i] = ((int16_t)(BTShortLock.Stitches*100));
				break;
				
			case 0x59:// 后密缝机械角度
				VsTemp[i] = ((int16_t)(BTShortLock.MechTheta>> 3));
				break;
					
			case 0x60://
				VsTemp[i] = ((int16_t)(FeedDir * 100));
				break;
						
			case 0x61:
				VsTemp[i] = ((int16_t)VBus);
				break;
          
			case 0x62:
				VsTemp[i] = ((int16_t)flagTheta0Test);
				break;
          
			case 0x63:
				VsTemp[i] = ((int16_t)TestTheta0Step);
				break;
					
			case 0x64:
				VsTemp[i] = ((int16_t)Timer0_CAR0);
				break;
				
			case 0x65:
				VsTemp[i] = ((int16_t)Timer0_CAR1);
				break;
					
			case 0x66:
				VsTemp[i] = ((int16_t)Timer0_CAR2);
				break;
					
			case 0x67:
				VsTemp[i] = ((int16_t)READ_SERVO_QEPCNT);
				break;
					
			case 0x68:
				VsTemp[i] = ((int16_t)(_IQtoF(ServoScaleIu) * 10000));	// 10为电流标幺值
				break;
					
			case 0x69:
				VsTemp[i] = ((int16_t)(_IQtoF(ServoScaleIv) * 10000));	// 10为电流标幺值
				break;
					
			case 0x70:// 速度环PI输出[0.1V]
				VsTemp[i] = ((int16_t)(_IQtoF(ServoPidSpeed.Out) * 10000)); 
				break;
				
			case 0x71: //歩进抬压脚运行角度
				VsTemp[i] = ((int16_t)(StepPress.ThetaELock));			
				break;
					
			case 0x72:// 速度反馈[rpm]
				VsTemp[i] = ((int16_t)(_IQtoF(ServoPidSpeed.Fdb) * ParamSpdPu)); 
				break;
					
			case 0x73://d轴电流反馈[0.1A]
				VsTemp[i] = ((int16_t)(_IQtoF(Servo_PidId.Fdb) * 10000));	// 10为电流标幺值; 
				break;
					
			case 0x74:// q轴电流指令[0.1A]
				VsTemp[i] = ((int16_t)(_IQtoF(Servo_PidIq.Ref) * 10000)); 
				break;
					
			case 0x75:// q轴电流反馈[0.1A]
				VsTemp[i] = ((int16_t)(_IQtoF(Servo_PidIq.Fdb) * 10000)); 
				break;
					
			case 0x76:// 伺服电机过流标志
				VsTemp[i] = ((int16_t)(ServoOverCurFlag) * 100); 
				break;
					
			case 0x77:// u相電流采样
				VsTemp[i] = (int16_t)(Servo_AdcIu); 
				break;
				
			case 0x78:// v相電流采样
				VsTemp[i] = (int16_t)(Servo_AdcIv); 
				break;
					
			case 0x79:// 夹线步骤
				VsTemp[i] = ((int16_t)(StateClamp * 100));
				break;
							
			case 0x80:// d轴PI输出[0.1V]
				VsTemp[i] = ((int16_t)(_IQtoF(Servo_PidId.Out) * 10000));
				break;
				
			case 0x81:// q轴PI输出[0.1V]
				VsTemp[i] = ((int16_t)(_IQtoF(Servo_PidIq.Out) * 10000));
				break;
          
      case 0x82://步进U相电流反馈
				VsTemp[i] = ((int16_t)(_IQtoF(StepScaleIu) * 10000));	// 10为电流标幺值
				break;
          
			case 0x83://步进v相电流反馈
				VsTemp[i] = ((int16_t)(_IQtoF(StepScaleIv) * 10000));	// 10为电流标幺值
				break;
          
			case 0x84:
				VsTemp[i] = ((int16_t)(_IQtoF(Servo_iPark.Alpha) * 10000));	// 10为电流标幺值
				break;
          
			case 0x85:
				VsTemp[i] = ((int16_t)(_IQtoF(Servo_iPark.Beta) * 10000));	// 10为电流标幺值
				break;
          
			case 0x86:
				VsTemp[i] = ((int16_t)(_IQtoF(Servo_Park.Qs) * 10000));	// 10为电流标幺值
				break;
          
			case 0x87:
				VsTemp[i] = ((int16_t)(InitPosFlag * 1000));	// 10为电流标幺值
				break;
          
			case 0x88:
				VsTemp[i] = ((int16_t)(_IQ16toF(ServoTheta)* 360));	// 10为电流标幺值
				break;
			
			case 0x89:
				VsTemp[i] = ((uint16_t)(_IQ16toF(ThtamUp)* 360));	// 10为电流标幺值
				break;
					
			case 0x90:
				VsTemp[i] = ((int16_t)(_IQ16toF(AbsThtamUpTest)* 360))	;//((uint16_t)(LockTimes *100));	       // 10为电流标幺值
				break;	
					
			case 0x91:
				VsTemp[i] = ((uint16_t)(TestFlag1  *100));	
				break;	
					
			case 0x92:
				VsTemp[i] = ((uint16_t)(ZJCapChaFlg * 100)); 
				break;

      case 0x93://起缝微抬状态
        VsTemp[i] = ((int16_t)(StepPresser.PressState * 100));	
        break;

			case 0x94:// 电气角度方向状态机标识符
				VsTemp[i] = ((uint16_t)(PosIndex * 100)); 
				break;
					
			case 0x95:// 电机运行状态
				VsTemp[i] = ((int16_t)(ServoMotorState * 100));
								 
				break;

			case 0x96://找初始位置得到的电角度值
				VsTemp[i] = ((int16_t)(_IQ16toF(InitServoTheta)* 360)); 
				break;

			case 0x97://提针标志
				VsTemp[i] = ((int16_t)(FlagNeedleLift * 100)); 
				break;

			case 0x98://允许补针标志
				VsTemp[i] = ((int16_t)(WorkState.FlagComPin * 100)); 
				break;		

			case 0x99://多段缝针数
				VsTemp[i] = ((int16_t)(StitchOneSeg.StitchCnt * 100)); 
				break;	

			case 0x100://步进电角度
				VsTemp[i] = ((int16_t)(_IQ16toF(StepTheta)* 360)); 
				break;	

       case 0x101://缝纫针距
        VsTemp[i] = ((int16_t)(FeedSewLength * 100)); 
        break;	

			case 0x102://步进速度给定
				VsTemp[i] = ((int16_t)((_IQtoF(StepSpeedRef) * ParamSpdPu))); 
			//  VsTemp[i] = ((int16_t)((_IQtoIQ16(StepSpeedRef))));  
				break;

			case 0x103://步进速度反馈
				VsTemp[i] = ((int16_t)((_IQtoF(StepSpeedFdb) * ParamSpdPu))); 
			//   VsTemp[i] = ((int16_t)((_IQtoIQ16(StepSpeedFdb))));
				break;

			case 0x105://限速切换状态
				VsTemp[i] = ((int16_t)(SoftTurn.SoftTurnState * 100)); 
				break;

			case 0x106://歩进光编计数
				VsTemp[i] = ((uint16_t)(READ_STEP_QEPCNT)); 
				break;

			case 0x107://步进准备
				VsTemp[i] = ((int16_t)MotorStepController.WorkReady * 100);
				break;

			case 0x108://步进电角度
				VsTemp[i] = ((int16_t)(StepThetaE.ThetaERefZEdge >> 8)); 
				break;	

			case 0x109://缝纫针距
				VsTemp[i] = ((int16_t)(_IQ16toF(StepThetaE.ThetaETarget) * 360));  
				break;	

			case 0x110://步进速度给定
				VsTemp[i] = ((int16_t)((_IQ16toF(StepThetaE.ThetaEDelta) * 360)));
				break;

			case 0x111://步进位置环输出
				VsTemp[i] = PositionLoop.VelOut >> 16;
				break;

			case 0x112://限速切换状态
				VsTemp[i] = ((uint16_t)PositionLoop.VelOut) >> 2;
				break;

			case 0x113://限速切换状态
//				VsTemp[i] = ((int16_t)(PositionLoop.ThetaEErr >> 8)); 
				VsTemp[i] = ((int16_t)((_IQ16toF(PositionLoop.ThetaEErr) * 360))); 
				break;

			case 0x114://步进工作步骤
				VsTemp[i] = MotorStepController.WorkStep * 100;
				break;
				
			case 0x115://步进准备
				VsTemp[i] = ((int16_t)PositionLoop.State * 100);//((uint16_t)TempVelOut) >> 2;
				break;  

			case 0x116://步进速度环输出
				VsTemp[i] =((int16_t)(_IQtoF(StepPidSpeed.Out) * 10000));	// 10为电流标幺值
				break; 

			case 0x117://步进d轴电流反馈
				VsTemp[i] =((int16_t)(_IQtoF(Step_PidId.Fdb) * 10000));	// 10为电流标幺值
				break; 

			case 0x118://步进q轴电流反馈
				VsTemp[i] =((int16_t)(_IQtoF(Step_PidIq.Fdb) * 10000));	// 10为电流标幺值
				break; 

			case 0x119://步进d轴电流给定
				VsTemp[i] =((int16_t)(_IQtoF(Step_PidId.Ref) * 10000));	// 10为电流标幺值
				break; 

			case 0x120://步进q轴电流给定
				VsTemp[i] =((int16_t)(_IQtoF(Step_PidIq.Ref) * 10000));	// 10为电流标幺值
				break; 
						
			case 0x121://测试标志
				VsTemp[i] =((int16_t)(DailSoftStarFlag*100));	
				break;

			case 0x122://D轴电压
//				VsTemp[i] =((int16_t)(_IQtoF(Step_LockVsd) * 1000));	
				VsTemp[i] =((int16_t)(_IQtoF(Step_LockVsd) * 10000)); 
				break;

			case 0x123://实际速度给定
				VsTemp[i] =((int16_t)(_IQtoF(StepSpeedFactRef) * ParamSpdPu));	
				break;

			case 0x124://锁定电角度
				VsTemp[i] =((int16_t)(_IQ16toF(StepThetaE.ThetaEStore) * 360));	
				break;

			case 0x125://压脚状态
				VsTemp[i] =((int16_t)(PressLiftState * 100));	
				break;

			case 0x126://交流电压
				 VsTemp[i] = ((int16_t)VoltAc.VoltAcOut30ms); 
				 break;

			case 0x127://去刹车电阻控制状态			
			  VsTemp[i] =((int16_t)( PidVbus.State * 100));		
				break;

			case 0x128://测试2
				VsTemp[i] =((int16_t)(TestFlag2 ));	
				break;

			case 0x129://步进电流给定状态
				VsTemp[i] =((int16_t)(StepCurRefState * 100));	
				break;

			case 0x130://测试3
				VsTemp[i] =((int16_t)(TestFlag3));	
				break;

			case 0x131://电压给定最小值
				VsTemp[i] =((int16_t)(NeedlePitchVsdRefMin * 100));	
				break;

			case 0x132://锁存标志
				VsTemp[i] =((int16_t)(NeedlePitchVsdMinIdleSaveFlag * 100));	
				break;

      case 0x133://步进dq轴合成电流值 
        VsTemp[i] =((int16_t)(_IQtoF(ComposerTemp) * 10000));
        break;

			case 0x134://测试6
				VsTemp[i] =((int16_t)(TestFlag6));	
				break;

			case 0x135://步进电机电角度
				VsTemp[i] =((int16_t)(_IQ16toF(StepThetaE.ThetaEReal) * 360));
				break;

			case 0x136://调针距弹簧状态
				VsTemp[i] =((int16_t)(NeedlePitchSpringState * 100));
				break;
				
			case 0x137://步进上一次控制步骤
				VsTemp[i] = MotorStepController.WorkStepOld * 100;
				break;

			case 0x138://步进找零点步骤
				VsTemp[i] = FindIndexZ.FindStep * 100;
				break;

			case 0x139://抬压脚抬起步骤
		     VsTemp[i] = MotorStepController.PresserUpStep * 100;
				break;
				
			case 0x140://步进w相电流反馈
				VsTemp[i] = ((int16_t)(_IQtoF(-(StepScaleIv + StepScaleIu)) * 10000));	// 10为电流标幺值
				break;

      case 0x141:// 多段缝当前段
        VsTemp[i] = ((int16_t)(NSegSew.NowSeg * 100));
        break;

      case 0x142://步进Z信号位置
        VsTemp[i] = MotorStepController.CHZPosQeiCnt;
        break;

			case 0x143://步进Z信号
//				VsTemp[i] = ((int16_t)(STEPCHANNEL_Z_CHECKED() * 100));
        VsTemp[i] = STEPCHANNEL_Z_CHECKED();
				break;

							case 0x144://步进开环角度指向累加				
								VsTemp[i] =((int16_t)(_IQ16toF(FindIndexZ.ThetaEAdd) * 360));
								break;
										
							case 0x145://距离目标位置差
								VsTemp[i] = ((int16_t)(MotorStepController.DeltPosQeiCnt));
								break;
								
							case 0x146:// q轴PI输出
								VsTemp[i] = ((int16_t)(_IQtoF(Step_PidIq.Err) * 10000));
								break;
								
							case 0x147:// q轴PI输出
								VsTemp[i]= ((int16_t)(_IQtoF(Step_PidIq.DeltaErr) * 10000));
								break;
								
							case 0x148:// q轴PI输出
								VsTemp[i] = ((int16_t)(_IQtoF(Step_PidIq.OutPreSat) * 10000));
								break;
				
							case 0x149:// q轴PI输出
								VsTemp[i] = ((int16_t)(_IQtoF(Step_PidIq.OutMax) * 10000));
								break;
								
							case 0x150:// 目标位置
								VsTemp[i] = ((int16_t)(MotorStepController.TargetPosQeiCnt));
								break;
								
							case 0x151:// 步进位置环控制步骤
								VsTemp[i] = ((int16_t)(PositionLoop.RunStep*100));
								break;
										
							case 0x152://步进电机目标角度
								VsTemp[i] =((int16_t)(_IQ16toF(MotorStepController.TargetPosTheta) * 360));
								break;
				
			case 0x153://步进电机当前角度
				VsTemp[i] =((int16_t)(_IQ16toF(MotorStepController.NowPosTheta) * 360));
				break;
				
			case 0x154://步进q轴电流给定
				VsTemp[i] =((int16_t)(_IQtoF(MotorStepController.CurLpIqRef) * 10000));	// 10为电流标幺值
				break; 
				
			case 0x155:// ipark ds
				VsTemp[i] = ((int16_t)(_IQtoF(Step_iPark.Ds) * 10000));
				break;
			
			case 0x156:// ipark qs
				VsTemp[i] = ((int16_t)(_IQtoF(Step_iPark.Qs) * 10000));
				break;
			
			case 0x157:// Step_PidId.Out
				VsTemp[i] = ((int16_t)(_IQtoF(Step_PidId.Out) * 10000));
				break;
			
			case 0x158:// Step_PidIq.Out
				VsTemp[i] = ((int16_t)(_IQtoF(Step_PidIq.Out) * 10000));
				break;
		
			case 0x159:// 步进pwm工作模式
				VsTemp[i] = ((int16_t)(PWMController.PWMMode*100));
				break;
		
			case 0x160://步进电机给定电压角度
				VsTemp[i] =((int16_t)(_IQ16toF(FindIndexZ.ThetaELock) * 360));
				break;
			
			case 0x161://步进真实速度给定
				VsTemp[i] = ((int16_t)((_IQtoF(StepSpeedRealRef) * ParamSpdPu))); 
				break;
			
			case 0x162:// 电机距离目标点状态
				VsTemp[i] = ((int16_t)(MotorStepController.GetTarget*100));
				break;
						
			case 0x163:// 当前机械机械角度脉冲计数
				VsTemp[i] = ((int16_t)(StepThetaE.SumEncMachine));
				break;
			
			case 0x164:// 位置环控制类型
				VsTemp[i] = ((int16_t)(MotorStepController.PositionLoopClass*100));
				break;
						
			case 0x165:// 位置环速度最小值
				VsTemp[i] = ((int16_t)(_IQtoF(PositionLoop.VelMin) * ParamSpdPu));
				break;
						
			case 0x166:// 目标距离弧度
				VsTemp[i] = (int16_t)(_IQ16toF(PositionSpeedPlan.DistanceRadian)*360);
				break;
			
			case 0x167:// 步进加速时间
				VsTemp[i] = ((int16_t) PositionSpeedPlan.PlanAccTime);
				break;			

			case 0x168:// 步进速度规划步骤
				VsTemp[i] = ((int16_t) PositionSpeedPlan.PlanStep*100);
				break;				
				
			case 0x169:// 缝制过程状态完成标志
				VsTemp[i] = ((int16_t) WorkState.StateOverFlag*100);
				break;
			
			case 0x170:// 校准后运行AB信号计数
				VsTemp[i] = ((int16_t) StepThetaE.SumEncReal);
				break;
			
			case 0x171:// 母线电压
				VsTemp[i] = ((int16_t)VBus);
				break;
			
			case 0x172:// 步进编码器计数
				VsTemp[i] = ((int16_t)IncEncoder.QeiCnt);
				break;
			
			case 0x173:// 减速总路径
				VsTemp[i] = ((int16_t)ServoStop.Path);
				break;
				
			case 0x174://减速需要的圈数
				VsTemp[i] = ((int16_t)ServoStop.Round*100);
				break;
			
			case 0x175:// 开始减速位置
				VsTemp[i] = ((int16_t)ServoStop.SlowPoint);
				break;
			
			case 0x176://下停针点为起点的机械角度
				 VsTemp[i] = ((int16_t)(_IQ16toF(ThtamDn)* 360)); 
				 break;	
					
			case 0x177://伺服停车Id给定标识
				 VsTemp[i] = ((int16_t)(ServoStopId* 100)); 
				 break;
							
		  case 0x178://伺服停车Id给定标识
								VsTemp[i] = ((int16_t)(StepPIControl* 100)); 
								 break;
							
							case 0x179://U电流反馈 0xb9
								 VsTemp[i] = BTackingSew.SpeedLink*100;
								 break;
							
							case 0x180://V电流反馈	
								 VsTemp[i] = OneLastSew*100;
								 break;
							
							case 0x181://步进位置反馈
								 VsTemp[i] =  TestFlag8*100;;
								 break;
							
							case 0x182://步进位置给定
								 VsTemp[i] = NSegSew.NSegmentIn*100;
								 break;
							
							case 0x183://工作状态	0xbd
								 VsTemp[i] = NSegSew.NowSegOld*100;
								 break;
							
							case 0x184://步进Q轴电流反馈
								 VsTemp[i] = NSegSew.NowSegKeepOld*100;
								 break;

							case 0x185://步进Q轴电流给定
								 VsTemp[i] = TestFlag9*10;
								 break;
							
							case 0x186:			//0xc0
							 VsTemp[i] = FTackingSew.SpeedLink*100;
								 break;
													
							case 0x187:
								 VsTemp[i] = NSegSew.NowSegFinishFlag*100;
								 break;
							
							case 0x188:
								 VsTemp[i] = XF_FOOT_PIN*100;//((int16_t)(QEPSumStar));  //ErrDateSaved9[ErrDataCnt];
								 break;
							
							case 0x189:
								 VsTemp[i] =  SX_FOOT_PIN*100;////ErrDateSaved10[ErrDataCnt];
								 break;

							case 0x190://步进Q轴电流给定	0xc4
								 VsTemp[i] = CLAMP_FOOT_PIN*100;//ErrDateSaved11[ErrDataCnt];
								 break;
							
							case 0x191://步进Q轴电流给定
								 VsTemp[i] = BX_FOOT_PIN*100;//ErrDateSaved12[ErrDataCnt];
								 break;
							
							case 0x192://U电流反馈 0xb9
								 VsTemp[i] = ((int16_t)(_IQ16toF(QEPUp)* 1440)); //ErrDate[ErrDataCnt];
								 break;
							
							case 0x193://V电流反馈	
								 VsTemp[i] = ((int16_t)(QEPSumStar)); //ErrDate2[ErrDataCnt];
								 break;
							
							case 0x194://步进位置反馈
								 VsTemp[i] = FlagSewed;//ErrDate3[ErrDataCnt];
								 break;
							
							case 0x195://步进位置给定
								 VsTemp[i] = ErrDate4[ErrDataCnt];
								 break;
							
							case 0x196://工作状态	0xbd
								 VsTemp[i] = ErrDate5[ErrDataCnt];
								 break;
							
							case 0x197://步进Q轴电流反馈
								 VsTemp[i] = ErrDate6[ErrDataCnt];
								 break;

							case 0x198://步进Q轴电流给定
								 VsTemp[i] = OneSegPreOn;//ErrDate7[ErrDataCnt];
								 break;
							
							case 0x199:			//0xc0
								 VsTemp[i] = ErrCode*100;
								 break;
													
							case 0x200:
								 VsTemp[i] = SpeedDec / IQ24DIV10000;	;//ErrDate8[ErrDataCnt];
								 break;
							
							case 0x201:
								 VsTemp[i] = StepPreActAngleTemp /182;
								 break;
							
							case 0x202:
								 VsTemp[i] = BTackingSew.SpeedSewing /2796;//ErrDate10[ErrDataCnt];
								 break;

							case 0x203://步进Q轴电流给定	0xc4
								 VsTemp[i] = BTackingSew.MaxSpeed /2796;//ErrDate11[ErrDataCnt];
								 break;
							
							case 0x204://步进Q轴电流给定
								 VsTemp[i] = BTackingSew.StrenSewDelay;
								 break;
                 
             case 0x205://步进Q轴电流给定
								 VsTemp[i] = SERVOCHANNEL_Z_CHECKED() ;
                 break;
              
             case 0x206://拨线电磁铁标志
                 VsTemp[i] = (BX_flag*100) ;
                 break;
                            
            case 0x207://松线电磁铁标志
                 VsTemp[i] = (SX_flag*100) ;
                 break;
             
            case 0x208://夹线电磁铁标志   
//                 VsTemp[i] = ( StateXF*100) ;
                 VsTemp[i] = ( QX_flag*100) ;
                  break;
          case 0x209://夹线电磁铁标志  
             VsTemp[i] = (int16_t)(  _IQabs(_IQtoF(StepMaxCurrent) * 10000)) ;
                  break;
          
             case 0x210://缝纫针距
              VsTemp[i] = ((int16_t)(SewLength * 100)); 
              break;	
              
              
              
             case 0x211://缝纫test
              VsTemp[i] = HmiSewParam.SewMode;//((int16_t)(TestFlagLength * 100)); MotorStallQepInit
              break;	
        
              case 0x212://缝纫test
              VsTemp[i] = ((int16_t)(MainSewLength * 100));//AutoCheckStart;//((int16_t)(TestFlagLength * 100)); Butonstate
              break;	
        
              case 0x213://缝纫test
              VsTemp[i] = AutoCheckID;//((int16_t)(TestFlagLength * 100)); Butonstate
              break;	
        
                           
             case 0x214://缝纫test
              VsTemp[i] =abs_s( (int16_t)(READ_SERVO_QEPCNT - (-32760)));//((int16_t)(TestFlagLength * 100)); 
              break;	
        
              case 0x215://缝纫test
              VsTemp[i] = abs_s((int16_t)(READ_SERVO_QEPCNT - (32760)));//((int16_t)(TestFlagLength * 100)); Butonstate
              break;	
        
              case 0x216://缝纫test
              VsTemp[i] = abs_s( (int16_t)(READ_SERVO_QEPCNT - 1));//((int16_t)(TestFlagLength * 100)); Butonstate
              break;	
         
              case 0x217://缝纫test
              VsTemp[i] = (int16_t)( READ_SERVO_QEPCNT );//((int16_t)(TestFlagLength * 100)); Butonstate
              break;	
              
              case 0x218://
              VsTemp[i] = (int16_t)(  _IQabs(_IQtoF(StepPidSpeed.Kp * 100))) ;//((int16_t)(TestFlagLength * 100)); Butonstate
              break;	  
              
              case 0x219:
              VsTemp[i] = (int16_t)(  _IQabs(_IQtoF(StepPidSpeed.Ki * 100))) ;//((int16_t)(TestFlagLength * 100)); Butonstate
              break;	
              
              case 0x220://StatePowerStop
              VsTemp[i] = ((int16_t)FirstSoftStart.StitchCnt*100) ;//((int16_t)(TestFlagLength * 100)); Butonstate
              break;	
              
              case 0x221://StatePowerStop
              VsTemp[i] = ((int16_t)SoftStart.FlagCounted*100);//((int16_t)MotorStallFlg*100) ;//((int16_t)(TestFlagLength * 100)); Butonstate
              break;	
              
              case 0x222://StatePowerStop
              VsTemp[i] = ((int16_t)SoftStart.StitchCnt*100) ;//((int16_t)(TestFlagLength * 100)); Butonstate
              break;	
                            
                          		
			case 0x223://Uμ?á÷·′à? 0xb9
				 VsTemp[i] = (int16_t)(StepParam.PressHeightTemp);
				 break;
			
			case 0x224://Vμ?á÷·′à?	
				  VsTemp[i] = ((int16_t)(StepParam.PressHeight)); 
				 break;
			
			case 0x225://2???????·′à?
				 VsTemp[i] = (int16_t)KneePressHeight;
				 break;
			
			case 0x226://2??????????¨
				 VsTemp[i] =(int16_t)(PressType*100);
				 break;
			
			case 0x227://1¤×÷×′ì?	0xbd
				VsTemp[i] = (int16_t)(SewAlarmFlag.KneealrFlag*100);
				 break;
			
			case 0x228://2???Q?áμ?á÷·′à?
				VsTemp[i] = ((int16_t)(KneePressQuickFlag*10));
				 break;

			case 0x229://2???Q?áμ?á÷???¨
				 VsTemp[i] = (int16_t)(KneeHeightUpdateEn);
				 break;
									
			case 0x230:
				 VsTemp[i] = (int16_t)(KnessHigh);
				 break;
			
			case 0x231:
				 VsTemp[i] = (int16_t)(PressHighDecFlag);
				 break;
			
			case 0x232:
				 VsTemp[i] = PressCloseRange;//ErrDate10[ErrDataCnt];
				 break;

			case 0x233://2???Q?áμ?á÷???¨	0xc4
				 VsTemp[i] = PressFarRange;//ErrDate11[ErrDataCnt];
				 break;
			
			case 0x234://2???Q?áμ?á÷???¨
				 VsTemp[i] = TestFlag99*100;//DeltPosQeiCntOld;//ErrDate12[ErrDataCnt];
				 break;
                 
      case 0x235:
				 VsTemp[i] = DailModeOpt*100;//ErrDate13[ErrDataCnt];
				 break;
			
			case 0x236:
				 VsTemp[i] = KnessNoWork*100;//ErrDate14[ErrDataCnt];
				 break;
                 
                 case 0x237://厚薄ADC采集值
          VsTemp[i] = ((int16_t)AdcHbTest);
          break;
          
      case 0x238://厚薄检测电压值
          VsTemp[i] = ((int16_t)VHbTest);
          break;
          
      case 0x239://厚薄厚料标志
          VsTemp[i] = ((int16_t)HbTest.FlagThick*100);
          break;
          
      case 0x240://厚薄计针数
          VsTemp[i] = ((int16_t)HbTest.StitchCnt*100);
          break;
          
      case 0x241://厚薄状态切换标志
          VsTemp[i] = ((int16_t)HbTest.FlagState*100);
          break;	
          
      case 0x242://厚薄检测ADC采样电压值
          VsTemp[i] = ((int16_t)HbTest.VHBadc);
          break;	
          
      case 0x243:
          VsTemp[i] = S3BranchStep;//HbTestAdc;
          break;
          
      case 0x244:
          VsTemp[i] = BranchStep;//((int16_t)HbTest.StateOld*10);
          break;
          
      case 0x245://校准零位值测试过程
          VsTemp[i] = FlagStartQepMode2;//((uint16_t)FlagAutocalState *100);
          break;
          
      case 0x246://校准零位值测试过程标志
          VsTemp[i] = M2Output.FbkData;//((uint16_t)AutocalStateOverFlag *100);
          break;
          
      case 0x247:
          VsTemp[i] = ((int16_t)(WorkState.StateOld *100)); 
          break;
          
      case 0x248://校准零位值
          VsTemp[i] = ((uint16_t)AutoHbTestAdc);
          break;
          
      case 0x249:
          VsTemp[i] = SpiBusMaster.NodeSyncFinish*100;//((uint16_t)TestFlag30 *100);
          break;
          
      case 0x250://过厚模式针距补偿值
          VsTemp[i] = ((uint16_t)AutoStitchOffset *100);
          break;

      case 0x251://后拖轮状态
          VsTemp[i] = ((uint16_t)(KWDragCtrlState *100));
          break;
          
      case 0x252://子报错码
          VsTemp[i] = ((uint16_t)(SubErrCode *100));
          break;
          
      case 0x253:
          VsTemp[i] = ((int16_t)(_IQ16toF(ServoStallThtam)* 360)); 
          break;
          
      case 0x254://面板型号
          VsTemp[i] = ((uint16_t)(MBModel *100)); 
          break;
          
      case 0x255://针数计数
          VsTemp[i] =	(int16_t)(StitchesCount * 100);
          break;	
       
      case 0x256://薄厚传感器未接报警标志  0：正常  1：报警
          VsTemp[i] =((uint16_t)(BHAlrFlag *100)); 
          break;
          
      case 0x257:// 步进2 u相電流采样
          VsTemp[i] = (int16_t)(Step2_AdcIu); 
          break;
          
      case 0x258:// 步进2 v相電流采样
          VsTemp[i] = (int16_t)(Step2_AdcIv); 
          break;
          
      case 0x259://特殊模式
          VsTemp[i] = SpecialModeFlag;
          break;	
          
      case 0x260:
          VsTemp[i] = ((uint16_t)(TestFlag1  *100));	
          break;	
          
      case 0x261:
          VsTemp[i] =((int16_t)(QEPSumFollow)); 
          break;
          
      case 0x262://
          VsTemp[i] = (PORT_GetBit(STEP_JX2_PORT,STEP_JX2_PIN));	
          break;
          
      case 0x263:// 
          VsTemp[i] = CutStepState;//(PORT_GetBit(STEP_JX1_PORT,STEP_JX1_PIN)); 
          break;
          
      case 0x264:////鸟巢及剪线状态
          VsTemp[i] = NestAndCutTargetPos*100;
          break;
          
      case 0x265://
          VsTemp[i] = S2MotorController.GetTarget*100;
          break;
          
      case 0x266://
          VsTemp[i] = M1MotorSerachFlag*100;
          break;
          
      case 0x267://
          VsTemp[i] = S2FindIndexZ.FindTime;
          break;
          
      case 0x268://
          VsTemp[i] = S2PositionSpeedPlan2.PlanMaxSpeed;
          break;
          
      case 0x269://
          VsTemp[i] =S2PositionSpeedPlan.PlanStep*100;
          break;
          
      case 0x270://
          VsTemp[i] = ((int16_t) (_IQtoF(S2PositionLoop.VelOut) * 6000));
          break;
          
      case 0x271://
          VsTemp[i] = Step2_AdcIuOffset;
          break;
          
      case 0x272://
          VsTemp[i] = Step2_AdcIvOffset;
          break;
          
      case 0x273://步进2光编信号
          VsTemp[i] = ((int16_t)(READ_S2_QEPCNT));
          break;
          
      case 0x274://步进2 Z信号
          VsTemp[i] = ((int16_t)(S2CHANNEL_Z_CHECKED()));
          break;
          
      case 0x275://步进2 U相电流
          VsTemp[i] = ((int16_t)(_IQtoF(S2ScaleIu) * 10000));
          break;
          
      case 0x276://步进2 V相电流
          VsTemp[i] = ((int16_t)(_IQtoF(S2ScaleIv) * 10000));
          break;
          
      case 0x277://步进2 速度反馈
          VsTemp[i] = ((int16_t) (_IQtoF(S2PidSpeed.Fdb) * 6000));
          break;
          
      case 0x278:	//步进2 速度给定
          VsTemp[i] = ((int16_t) (_IQtoF(S2PidSpeed.Ref) * 6000));
          break;
          
      case 0x279:
          VsTemp[i] = ((int16_t)(QEPSumStar));
          break;
          
      case 0x280:
          VsTemp[i] = ((int16_t)(QEPSumAll)); 
          break;
          
      case 0x281:// 步进2 d轴电流给定
          VsTemp[i] = ((int16_t)(_IQtoF(S2_PidId.Ref) * 10000));
          break;
          
      case 0x282:// 步进2 q轴电流给定
          VsTemp[i] = ((int16_t)(_IQtoF(S2_PidIq.Ref) * 10000));
          break;
          
      case 0x283://步进2 距离目标位置差
          VsTemp[i] = ((int16_t)(S2MotorController.DeltPosQeiCnt));
          break;
          
      case 0x284://
          VsTemp[i] = S2MotorController.NowPosQeiCnt;
          break;
          
      case 0x285://步进2目标位置
          VsTemp[i] = S2MotorController.TargetPosQeiCnt;
          break;
          
      case 0x286://
          VsTemp[i] = S2MotorController.PositionLoopClass;
          break;
          
      case 0x287:// 
          VsTemp[i] = S2MotorController.WorkStep;
          break;
          
      case 0x288:// 
          VsTemp[i] =S2FindIndexZ.FindStep;
          break;
          
      case 0x289://
          VsTemp[i] = ((int16_t)(_IQ16toF(S2FindIndexZ.ThetaELock) * 360));
          break;	 
          
      case 0x290://
          VsTemp[i] = ((int16_t)(_IQ16toF(S2ThetaE.ThetaEReal) * 360));
          break;	
          
      case 0x291://
          VsTemp[i] = ((int16_t)(_IQtoF(S2_PidId.Fdb) * 10000));
          break;	
          
      case 0x292://
          VsTemp[i] = ((int16_t)(_IQtoF(S2_PidIq.Fdb) * 10000));
          break;	
          
          case 0x293://
              VsTemp[i] = ((int16_t)StepLightPresser.PressEnState*100) ;
              break;	        
                          		
			case 0x294://
				 VsTemp[i] = S2WorkState.StateOut*100;
				 break;
			
			case 0x295://
				 VsTemp[i] = ThtamUpSum;//TestFlag111*100;
				 break;
			
			case 0x296://步进2堵转标志
				 VsTemp[i] = S2MotorStallFlg*100;
				 break;
			
			case 0x297:
				 VsTemp[i] = S2IndexOldState*100;
				 break;       

			case 0x298://倒缝按钮状态
				 VsTemp[i] = BackSewBtnState*100;
				 break;
									
			case 0x299://1/2按钮状态
				 VsTemp[i] = CompSewHalfBtnState*100;
				 break;
			
			case 0x300://1/4按钮状态
				 VsTemp[i] = CompSewquarterBtnState*100;
				 break;
			
			case 0x301://过梗时面板图标显示
				 VsTemp[i] =TrimMagnetFlag*100;//FlagMBDisplay*100;
				 break;

			case 0x302://步进2错误代码
				 VsTemp[i] =S2ErrCode*10;
				 break;
			
			case 0x303://鸟巢角度
				 VsTemp[i] = ((int16_t)(_IQ16toF(ThtamUpDial)* 360)); 
				 break;

      case 0x304:			//0xc0
          VsTemp[i] = 0;//
          break;     
          
      case 0x305:			//0xc0
          VsTemp[i] = S2ShakeWinFlg*100;//
          break;     
          
      case 0x306:			//0xc0
          VsTemp[i] = S2ShakeWinCnt;//StepPreStopDlyCnt;//
          break;     
          
      case 0x307:			//0xc0
          VsTemp[i] = S2ShakeWinQei;//TrimPressPreDlyCnt;//
          break;  
          
      case 0x308:			//0xc0
          VsTemp[i] = S2ShakeCnt;//TrimPressPreFlag;//
          break;     
          
      case 0x309:			//0xc0
          VsTemp[i] = S2ShakeFlag*100;//FlagStartQepRun;//AlwaysKeepOpt;//
          break;     
          
      case 0x310:			//0xc0
          VsTemp[i] = ((int16_t)(_IQ16toF(S2MotorController.ThetaELock) * 360));//
          break;   
          
      case 0x311:			//0xc0
          VsTemp[i] = StatePowerStop;//
          break;    
     
       case 0x312:			//0xc0
          VsTemp[i] = AssistCutStepState*100;//
          break;     
          
      case 0x313:			//0xc0
          VsTemp[i] = (uint16_t)FTShortLockNestDirect*10;//
          break;  
          
      case 0x314:// 前固缝重复遍数
          VsTemp[i] = ((int16_t)(FTShortLock.RepeatCnt*100));  
          break;
          
      case 0x315:
          VsTemp[i] =((int16_t) (_IQtoF(FTShortLock.SpeedSewing) * 6000));//ErrDate10[ErrDataCnt];
          break;
          
                case 0x316:
          VsTemp[i] = ((int16_t) (_IQtoF(TempSpeed) * 6000));//ErrDate10[ErrDataCnt];
          break;
          
      case 0x317:// 前密缝机械角度
          VsTemp[i] = ((int16_t)((StepBackSwitchAngle - StepPreActAngleTemp)>>3));
          break;
          
      case 0x318:// 前密缝机械角度
          VsTemp[i] = (int16_t)(StepFeedDirChgFlag*10);
          break;
          
      case 0x319:// 前密缝机械角度
          VsTemp[i] = (int16_t)(FTShortLock.EmagState*10);
          break;
          
      case 0x320:
          VsTemp[i] = EncAbsTheta; 	
          break;
          
      case 0x321:
          VsTemp[i] = CmpFlag * 1000; 	
          break;    
          
      case 0x322:
          VsTemp[i] = ((int16_t)SoftStart.Stitch*100);//StopTimeCnt; 	
          break;       
          
      case 0x323:			//0xc0
          VsTemp[i] = StepPreStopDlyCnt;//
          break;     
          
      case 0x324:			//0xc0
          VsTemp[i] = TrimPressPreDlyCnt;//
          break;  
          
      case 0x325:			//0xc0
          VsTemp[i] = TrimPressPreFlag;//
          break;     
          
      case 0x326:			//0xc0
          VsTemp[i] = AlwaysKeepOpt;//FlagStartQepRun;////   
          break;
          
      case 0x327:			//0xc0
          VsTemp[i] = SlaveErrCode;//FlagStartQepRun;////   
          break;
          
      case 0x328:			//0xc0
          VsTemp[i] = DragPowerOff;//FlagStartQepRun;////   
          break; 
          
      case 0x329:			//0xc0
          VsTemp[i] = DragErrNum;//FlagStartQepRun;////   
          break;
     
      case 0x330:			//0xc0
          VsTemp[i] = NestCutAngle3Tmp;//FlagStartQepRun;////   
          break;
          
      case 0x331:			//0xc0
          VsTemp[i] = FirstStitchXFCtrlFlag;//NestTrimFlag;//FlagStartQepRun;////   
          break;
      
      case 0x332:			//0xc0
          VsTemp[i] = TrimMagnetFlag;//FlagStartQepRun;////   
          break;  
          
      case 0x333:			//0xc0
          VsTemp[i] = (int16_t)(Step_AdcIu);//FlagStartQepRun;////   
          break;
          
     case 0x334:			//0xc0
          VsTemp[i] = (int16_t)(Step_AdcIv);//S2MotorStallCnt1;//FlagStartQepRun;////   
          break;
          
     case 0x335:			//0xc0
          VsTemp[i] = S2WorkState.StateOld;//TestFlag77;//FlagStartQepRun;////   
          break;
          
     case 0x336:			//0xc0
          VsTemp[i] = S2MotorStallWinCnt;//TestFlag77;//FlagStartQepRun;////   
          break;
          
     case 0x337:			//0xc0
          VsTemp[i] = S2MotorStallWinFlg*100;//TestFlag77;//FlagStartQepRun;////   
          break;
          
      case 0x338:			//0xc0
          VsTemp[i] = S2MotorStallCnt;//TestFlag77;//FlagStartQepRun;////   
          break;
          
      case 0x449:// 历史故障数据存储当前位置
          VsTemp[i] = HisFtData.NowStorePos;
          break;
          
		  default:
				// 故障时关键数据输出
                // 在线数据记录  //20241126-2
                if((VsRxVar.Addr[i] >= 0x400) && (VsRxVar.Addr[i] <= 0x415))
                {
                    Index = VsRxVar.Addr[i]-0x400;
                    if(Index >= 0x10)
                    {
                        Index = Index - 6;
                    }
                    if(Index<0)
                    {
                        Index = 0;
                    }
                    if(Index>15)
                    {
                        Index = 15;
                    }
                    VsTemp[i] = HisFtData.CacheTmp[Index][HisFtData.OutCnt];
                }
                // 区域0:
                if((VsRxVar.Addr[i] >= 0x500) && (VsRxVar.Addr[i] <= 0x515))
                {
                    Index = VsRxVar.Addr[i]-0x500;
                    if(Index >= 0x10)
                    {
                        Index = Index - 6;
                    }
                    if(Index<0)
                    {
                        Index = 0;
                    }
                    if(Index>15)
                    {
                        Index = 15;
                    }
                    VsTemp[i] = HisFtData.Cache0[Index][HisFtData.OutCnt];
                }
                // 区域1:
                if((VsRxVar.Addr[i] >= 0x600) && (VsRxVar.Addr[i] <= 0x615))
                {
                    Index = VsRxVar.Addr[i]-0x600;
                    if(Index >= 0x10)
                    {
                        Index = Index - 6;
                    }
                    if(Index<0)
                    {
                        Index = 0;
                    }
                    if(Index>15)
                    {
                        Index = 15;
                    }
                    VsTemp[i] = HisFtData.Cache1[Index][HisFtData.OutCnt];
                }
                // 区域2:
                if((VsRxVar.Addr[i] >= 0x700) && (VsRxVar.Addr[i] <= 0x715))
                {
                    Index = VsRxVar.Addr[i]-0x700;
                    if(Index >= 0x10)
                    {
                        Index = Index - 6;
                    }
                    if(Index<0)
                    {
                        Index = 0;
                    }
                    if(Index>15)
                    {
                        Index = 15;
                    }
                   VsTemp[i] = HisFtData.Cache2[Index][HisFtData.OutCnt];
                }
				break;
          
				}
            
//                if(VsRxVar.Addr[i]>= 0x300)
//                {
//                    VsTemp[i] = VsBuff.Out[i];
//                }
    }	
//		if(++ErrDataCnt>=100)//0-99
//		{
//				ErrDataCnt = 0;
//		}
//    		if(++ErrDataCnt>=ERRDATA_ARRDATANUM)//0-99
//		{
//				ErrDataCnt = 0;
//		}
//     VsBuff.DOut(&VsBuff);	
		

}

//================================================================================
//Function:			VSUartSendByte()
//Description:	发送一个字节数据（不能用这个函数发多个字节数据，会影响其他程序执行）
//Inputs:			
//Outputs:	
//Description: 
//================================================================================  
void VSUartSendByte(uint8_t Data)
{
    while(1 != USART_GetStatus(VSUSARTX, UsartTxEmpty));//获取USART状态寄存器标志位:发送数据缓冲区空   
    USART_SendData(VSUSARTX, Data);
    USART_FuncCmd(VSUSARTX, UsartTxAndTxEmptyInt, Enable);
		VsTxVar.TxCnt = 1;
		VsTxVar.TxNum = 1;	
			
}

//================================================================================
//Function:			VSUartSendnBytes()
//Description:	发送多个字节的数据
//Inputs:			
//Outputs:	
//Description: 
//================================================================================  
void VSUartSendnBytes(uint8_t *data,uint8_t len)
{
	  uint16_t i;
	
		while(1 != USART_GetStatus(VSUSARTX, UsartTxEmpty)); //获取USART状态寄存器标志位:发送数据缓冲区空  
		
		for(i=0;i<len;i++)
		{
				VsTxVar.TxBuf[i] = data[i];
		}		
                VsTxVar.TxNum = len;  //发送数据个数赋值	
		VsTxVar.TxCnt = 1;	//表示已发送1个数据	
		USART_SendData(VSUSARTX, data[0]);
		USART_FuncCmd(VSUSARTX, UsartTxAndTxEmptyInt, Enable);
		
}
