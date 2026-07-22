# Composite module so CONFIG_TOUCHSCREEN_SEC_TS=m produces a single sec_ts_drv.ko
ifeq ($(CONFIG_SAMSUNG_PRODUCT_SHIP), y)
  sec_ts_drv-y := sec_ts.o sec_ts_fw.o sec_ts_fn.o sec_ts_ioctl.o
else
  sec_ts_drv-y := sec_ts.o sec_ts_fw.o sec_ts_fn.o sec_ts_ioctl.o sec_ts_only_vendor.o
endif
obj-$(CONFIG_TOUCHSCREEN_SEC_TS) += sec_ts_drv.o
