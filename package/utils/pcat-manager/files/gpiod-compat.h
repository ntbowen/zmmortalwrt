#ifndef __GPIOD_COMPAT_H__
#define __GPIOD_COMPAT_H__

#include <gpiod.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>  // 添加这行，提供close函数的声明

// 这个文件提供了libgpiod1和libgpiod2之间的兼容层

// libgpiod1的结构和函数
struct gpiod_chip {
    int fd;
    char *name;
    char *path;
    struct gpiod_chip *real_chip;  // 存储真实的libgpiod2 chip
};

struct gpiod_line {
    unsigned int offset;
    struct gpiod_chip *chip;
    int fd;
    bool requested;
    struct gpiod_line_request *request;  // 存储真实的libgpiod2 request
};

// 适配函数 - 将libgpiod2的API转换为libgpiod1的API
static inline struct gpiod_chip *gpiod_chip_open_by_name(const char *name)
{
    if (!name || name[0] == '\0') {
        return NULL;
    }
    
    char chip_path[64];
    snprintf(chip_path, sizeof(chip_path), "/dev/%s", name);
    
    struct gpiod_chip *real_chip = gpiod_chip_open(chip_path);
    if (!real_chip) {
        fprintf(stderr, "gpiod_compat: Failed to open chip %s\n", name);
        return NULL;
    }
    
    // 创建兼容层的chip结构
    struct gpiod_chip *chip = (struct gpiod_chip *)malloc(sizeof(struct gpiod_chip));
    if (!chip) {
        fprintf(stderr, "gpiod_compat: Failed to allocate chip\n");
        gpiod_chip_close(real_chip);
        return NULL;
    }
    
    // 初始化chip结构
    chip->fd = -1;  // 我们不直接使用fd
    chip->name = strdup(name);
    chip->path = strdup(chip_path);
    chip->real_chip = real_chip;
    
    return chip;
}

static inline struct gpiod_line *gpiod_chip_get_line(struct gpiod_chip *chip, unsigned int offset)
{
    if (!chip || !chip->real_chip) {
        return NULL;
    }
    
    // 创建一个模拟的gpiod_line结构
    struct gpiod_line *line = (struct gpiod_line *)malloc(sizeof(struct gpiod_line));
    if (!line) {
        fprintf(stderr, "gpiod_compat: Failed to allocate line\n");
        return NULL;
    }
    
    // 初始化line结构
    line->offset = offset;
    line->chip = chip;
    line->fd = -1;  // 我们不直接使用fd
    line->requested = false;
    line->request = NULL;
    
    return line;
}

static inline bool gpiod_line_is_requested(struct gpiod_line *line)
{
    if (!line) {
        return false;
    }
    
    return line->requested;
}

static inline int gpiod_line_request_output(struct gpiod_line *line, const char *consumer, int default_val)
{
    if (!line || !line->chip || !line->chip->real_chip) {
        return -1;
    }
    
    // 在libgpiod2中，我们需要创建一个line_settings配置
    struct gpiod_line_settings *settings = gpiod_line_settings_new();
    if (!settings) {
        fprintf(stderr, "gpiod_compat: Failed to create line settings\n");
        return -1;
    }
    
    // 设置为输出模式
    gpiod_line_settings_set_direction(settings, GPIOD_LINE_DIRECTION_OUTPUT);
    gpiod_line_settings_set_output_value(settings, default_val ? GPIOD_LINE_VALUE_ACTIVE : GPIOD_LINE_VALUE_INACTIVE);
    
    struct gpiod_line_config *config = gpiod_line_config_new();
    if (!config) {
        fprintf(stderr, "gpiod_compat: Failed to create line config\n");
        gpiod_line_settings_free(settings);
        return -1;
    }
    
    // 添加偏移量到配置中
    if (gpiod_line_config_add_line_settings(config, &line->offset, 1, settings) < 0) {
        fprintf(stderr, "gpiod_compat: Failed to add line settings\n");
        gpiod_line_config_free(config);
        gpiod_line_settings_free(settings);
        return -1;
    }
    
    // 创建一个request_config对象
    struct gpiod_request_config *req_cfg = gpiod_request_config_new();
    if (!req_cfg) {
        fprintf(stderr, "gpiod_compat: Failed to create request config\n");
        gpiod_line_config_free(config);
        gpiod_line_settings_free(settings);
        return -1;
    }
    
    // 设置消费者名称
    if (consumer) {
        gpiod_request_config_set_consumer(req_cfg, consumer);
    }
    
    // 请求GPIO线
    struct gpiod_line_request *request = gpiod_chip_request_lines(line->chip->real_chip, req_cfg, config);
    if (!request) {
        fprintf(stderr, "gpiod_compat: Failed to request line as output\n");
        gpiod_request_config_free(req_cfg);
        gpiod_line_config_free(config);
        gpiod_line_settings_free(settings);
        return -1;
    }
    
    // 更新line结构
    line->request = request;
    line->requested = true;
    
    // 释放不再需要的资源
    gpiod_request_config_free(req_cfg);
    gpiod_line_config_free(config);
    gpiod_line_settings_free(settings);
    
    return 0;
}

static inline int gpiod_line_set_value(struct gpiod_line *line, int value)
{
    if (!line || !line->requested || !line->request) {
        return -1;
    }
    
    // 创建值数组
    enum gpiod_line_value values[1] = {
        value ? GPIOD_LINE_VALUE_ACTIVE : GPIOD_LINE_VALUE_INACTIVE
    };
    
    // 设置值
    if (gpiod_line_request_set_values(line->request, values) < 0) {
        fprintf(stderr, "gpiod_compat: Failed to set line value\n");
        return -1;
    }
    
    return 0;
}

static inline void gpiod_line_release(struct gpiod_line *line)
{
    if (!line) {
        return;
    }
    
    if (line->requested && line->request) {
        // 释放line_request
        gpiod_line_request_release(line->request);
        line->request = NULL;
        line->requested = false;
    }
    
    free(line);
}

// 不要重新定义已经存在的函数
// 我们使用真实的gpiod_chip_close函数
/*
static inline void gpiod_chip_close(struct gpiod_chip *chip)
{
    if (!chip) {
        return;
    }
    
    // 关闭芯片
    gpiod_chip_close(chip);
}
*/

// 替代的关闭函数
static inline void gpiod_chip_free(struct gpiod_chip *chip)
{
    if (!chip) {
        return;
    }
    
    // 关闭真实的芯片
    if (chip->real_chip) {
        gpiod_chip_close(chip->real_chip);
    }
    
    // 释放内存
    if (chip->name) {
        free(chip->name);
    }
    if (chip->path) {
        free(chip->path);
    }
    
    free(chip);
}

#endif /* __GPIOD_COMPAT_H__ */
