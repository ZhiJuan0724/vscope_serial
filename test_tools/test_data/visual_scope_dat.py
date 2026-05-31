import pandas as pd
class visual_scope_dat:
    def __init__(self, file_name : str, is_exbox : bool = False):
        self.file_name : str = file_name
        self.is_exbox : bool = is_exbox
        self.raw_datas = [[],[],[],[]]
        self.datas = [[],[],[],[]]
        try:
            with open(file_name, 'rb') as file:
                self.file_data = file.read()
                file.seek(0, 2)
                self.file_size = file.tell()
                if not self._check_data():
                    raise ValueError("这是一个错误的值")
        except FileNotFoundError:
            print("文件{filename}未找到，请检查文件路径")
        except ValueError:
            print("文件{filename}不是虚拟示波器的文件")

    def handle(self):
        self.ch_data_size = self._chx_data_len()
        self.ch_real_data_size = self.ch_data_size if(self.is_exbox) else self.ch_data_size - 50000
        self.addr = [self._get_chx_addr(1), self._get_chx_addr(2), self._get_chx_addr(3), self._get_chx_addr(4)]
        self.raw_datas = [self._get_chx_data(1), self._get_chx_data(2), self._get_chx_data(3), self._get_chx_data(4)]
        self._convert_date()
        return
    
    def get_addr(self, chx):
        return self.addr[chx - 1]
    
    def get_data(self, chx):
        return self.datas[chx - 1]
    
    def _check_data(self):
        len_date = (self.file_data[3] << 24) | (self.file_data[2] << 16) | (self.file_data[1]<< 8) | self.file_data[0]
        if len_date == self.file_size:
            return True
        else:
            return False
        
    def _chx_data_len(self):
        return (self.file_data[0x23] << 24) | (self.file_data[0x22] << 16) | (self.file_data[0x21] << 8) | self.file_data[0x20]
    
    def _get_chx_addr(self, chx):
        assert chx >= 1 and chx <= 4
        index = 0x04 + chx * 20 + (chx - 1) * self.ch_data_size * 2
        return (self.file_data[index + 3] << 24) | (self.file_data[index + 2] << 16) | (self.file_data[index + 1] << 8) | (self.file_data[index])
    
    def _get_chx_data(self, chx):
        assert chx >= 1 and chx <= 4
        start_index = 0x04 + chx * 32 + (chx - 1) * self.ch_data_size * 2
        end_index = start_index + self.ch_data_size * 2
        start_index += 100000 if not self.is_exbox else 0  #虚拟示波器默认从 50000 开始
        return self.file_data[start_index:end_index]
    
    def _convert_date(self):
        if len(self.raw_datas[0]) % 2 != 0:
            raise ValueError("数据错误")

        for i in range(0, len(self.raw_datas[0]), 2):
            temp = self.raw_datas[0][i : i + 2]
            number = int.from_bytes(temp, byteorder='little', signed=True)
            self.datas[0].append(number)
            
            temp = self.raw_datas[1][i : i + 2]
            number = int.from_bytes(temp, byteorder='little', signed=True)
            self.datas[1].append(number)
            
            temp = self.raw_datas[2][i : i + 2]
            number = int.from_bytes(temp, byteorder='little', signed=True)
            self.datas[2].append(number)
            
            temp = self.raw_datas[3][i : i + 2]
            number = int.from_bytes(temp, byteorder='little', signed=True)
            self.datas[3].append(number)
            
    def fixed_point_to_float(fixed_point_int_value: int) -> float:
        """
        将一个32位、24位小数部分的定点二进制小数转换为浮点数。

        Args:
            fixed_point_int_value: 表示32位定点数的整数值。

        Returns:
            转换后的浮点数。
        """
        TOTAL_BITS = 32
        FRACTIONAL_BITS = 24
        
        # 计算比例因子 (2的24次方)
        scale_factor = 2**FRACTIONAL_BITS

        # 检查最高位 (符号位)
        # 如果最高位是1，说明这是一个负数（在补码表示中）
        # TOTAL_BITS - 1 是最高位的索引
        if fixed_point_int_value & (1 << (TOTAL_BITS - 1)):
            # 这是一个负数。
            # 将无符号整数转换为对应的有符号整数（补码转换）
            # 例如，对于一个N位整数，如果其无符号值为X，其有符号值是 X - 2^N
            signed_int_value = fixed_point_int_value - (1 << TOTAL_BITS)
        else:
            # 这是一个正数
            signed_int_value = fixed_point_int_value
        
        # 将有符号整数值除以比例因子，得到浮点数
        float_value = signed_int_value / scale_factor
        return float_value
    
    def save_to_csv(self, file_name : str = ''):
        if file_name == '':
            file_name = self.file_name + '.csv'
        if len(self.datas[0]) == 0:
                self.handle()
        data = {
            'ch1': self.datas[0],
            'ch2': self.datas[1],
            'ch3': self.datas[2],
            'ch4': self.datas[3]
        }
        df = pd.DataFrame(data)
        df.to_csv(file_name, index_label = 'index', index= True)